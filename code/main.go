// spr-atlas: SPR plugin wrapping the RIPE Atlas software probe.
//
// Serves a JSON API + bundled UI over a Unix socket and supervises the probe
// main loop (/scripts/run-probe.sh). In krun mode, the spr-krun-plugin base
// maps this guest-local socket to vsock; libkrun maps vsock to SPR's
// host-visible Unix socket.
package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"syscall"
)

const unixPluginListener = "/state/plugins/spr-atlas/api/socket.sock"

// RegisterURL is where the admin submits the probe public key.
const RegisterURL = "https://atlas.ripe.net/apply/swprobe/"

func jsonResponse(w http.ResponseWriter, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(v); err != nil {
		log.Println("failed to encode response:", err)
	}
}

func handleGetStatus(sup *Supervisor) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		jsonResponse(w, sup.Status())
	}
}

// handleGetKey returns the probe's PUBLIC key only. The private key
// (probe_key) is never read by any handler.
func handleGetKey(w http.ResponseWriter, r *http.Request) {
	pub, err := ReadPublicKey(ProbeKeyPubFile)
	if err != nil {
		if os.IsNotExist(err) {
			jsonResponse(w, KeyInfo{Exists: false, RegisterURL: RegisterURL})
			return
		}
		http.Error(w, err.Error(), 500)
		return
	}
	pub.RegisterURL = RegisterURL
	jsonResponse(w, pub)
}

func handleRestart(sup *Supervisor) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if err := sup.Restart(); err != nil {
			http.Error(w, err.Error(), 500)
			return
		}
		jsonResponse(w, map[string]bool{"Success": true})
	}
}

func handleGetLogs(sup *Supervisor) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		lines := 200
		if v := r.URL.Query().Get("lines"); v != "" {
			n, err := strconv.Atoi(v)
			if err != nil || n < 1 || n > 1000 {
				http.Error(w, "lines must be an integer between 1 and 1000", 400)
				return
			}
			lines = n
		}
		jsonResponse(w, map[string][]string{"Lines": sup.Logs(lines)})
	}
}

// spaHandler serves the bundled UI (single self-contained index.html).
type spaHandler struct {
	staticPath string
	indexPath  string
}

func (h spaHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	path, err := filepath.Abs(r.URL.Path)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	path = filepath.Join(h.staticPath, path)
	_, err = os.Stat(path)
	if os.IsNotExist(err) {
		http.ServeFile(w, r, filepath.Join(h.staticPath, h.indexPath))
		return
	} else if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	http.FileServer(http.Dir(h.staticPath)).ServeHTTP(w, r)
}

func logRequest(handler http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Printf("%s %s %s\n", r.RemoteAddr, r.Method, r.URL)
		handler.ServeHTTP(w, r)
	})
}

func listenUnix(path string) (net.Listener, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0750); err != nil {
		return nil, err
	}
	if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
		return nil, err
	}
	listener, err := net.Listen("unix", path)
	if err != nil {
		return nil, err
	}
	if err := os.Chmod(path, 0770); err != nil {
		log.Printf("socket chmod unavailable for %s: %v", path, err)
	}
	return listener, nil
}

func pluginListener() (net.Listener, error) {
	path := os.Getenv("SPR_KRUN_PLUGIN_SOCKET")
	if path == "" {
		path = unixPluginListener
	}
	if !filepath.IsAbs(path) {
		return nil, fmt.Errorf("SPR_KRUN_PLUGIN_SOCKET must be an absolute path")
	}
	return listenUnix(path)
}

func main() {
	// The plugin socket is created on a host bind mount. Some filesystem
	// proxies cannot chmod an existing UDS, so request restrictive creation
	// permissions first and treat chmod as best-effort.
	syscall.Umask(0007)

	sup := NewSupervisor(ProbeCommand)

	mux := http.NewServeMux()
	mux.HandleFunc("GET /status", handleGetStatus(sup))
	mux.HandleFunc("GET /key", handleGetKey)
	mux.HandleFunc("POST /restart", handleRestart(sup))
	mux.HandleFunc("GET /logs", handleGetLogs(sup))
	mux.HandleFunc("GET /topology", handleGetTopology)
	mux.Handle("/", spaHandler{staticPath: "/ui", indexPath: "index.html"})

	listener, err := pluginListener()
	if err != nil {
		log.Fatalf("listen on plugin API failed: %v", err)
	}

	sup.Start()

	server := http.Server{Handler: logRequest(mux)}
	if err := server.Serve(listener); err != nil {
		panic(err)
	}
}
