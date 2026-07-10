package main

import (
	"bufio"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

// TEST_PREFIX lets unit tests point the file probes at a scratch dir.
var TEST_PREFIX = os.Getenv("TEST_PREFIX")

// ProbeCommand is what the supervisor launches (drops privileges + grants
// ambient cap_net_raw before exec'ing the probe main loop).
var ProbeCommand = "/scripts/run-probe.sh"

// Filesystem locations of the probe's runtime state (upstream FHS layout).
var (
	ProbeKeyPubFile   = TEST_PREFIX + "/etc/ripe-atlas/probe_key.pub"
	StatusDir         = TEST_PREFIX + "/run/ripe-atlas/status"
	FirmwareVersFile  = TEST_PREFIX + "/usr/share/ripe-atlas/FIRMWARE_APPS_VERSION"
	ProbeLogFile      = TEST_PREFIX + "/state/plugins/spr-atlas/log/probe.log"
	probeLogMaxBytes  = int64(5 * 1024 * 1024)
	ringCapacityLines = 1000
)

// ---------------------------------------------------------------------------
// Public key handling (GET /key). Only the .pub file is ever read.
// ---------------------------------------------------------------------------

type KeyInfo struct {
	Exists      bool
	PublicKey   string `json:",omitempty"`
	Fingerprint string `json:",omitempty"`
	Comment     string `json:",omitempty"`
	RegisterURL string
}

var allowedKeyTypes = []string{"ssh-rsa", "ssh-ed25519", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521"}

// ParsePublicKey validates that data is a single-line OpenSSH public key and
// returns its normalized form + SHA256 fingerprint. It refuses anything that
// looks like private key material.
func ParsePublicKey(data string) (KeyInfo, error) {
	info := KeyInfo{}
	if strings.Contains(data, "PRIVATE") {
		return info, errors.New("refusing to serve private key material")
	}
	line := strings.TrimSpace(data)
	if line == "" || strings.ContainsAny(line, "\r\n") {
		return info, errors.New("public key file must contain exactly one line")
	}
	fields := strings.Fields(line)
	if len(fields) < 2 {
		return info, errors.New("malformed public key")
	}
	keyType := fields[0]
	ok := false
	for _, t := range allowedKeyTypes {
		if keyType == t {
			ok = true
			break
		}
	}
	if !ok {
		return info, fmt.Errorf("unexpected key type %q", keyType)
	}
	blob, err := base64.StdEncoding.DecodeString(fields[1])
	if err != nil {
		return info, errors.New("malformed public key (bad base64)")
	}
	sum := sha256.Sum256(blob)
	info.Exists = true
	info.PublicKey = line
	info.Fingerprint = "SHA256:" + base64.RawStdEncoding.EncodeToString(sum[:])
	if len(fields) > 2 {
		info.Comment = strings.Join(fields[2:], " ")
	}
	return info, nil
}

func ReadPublicKey(path string) (KeyInfo, error) {
	f, err := os.Open(path)
	if err != nil {
		return KeyInfo{}, err
	}
	defer f.Close()
	data, err := io.ReadAll(io.LimitReader(f, 16*1024))
	if err != nil {
		return KeyInfo{}, err
	}
	return ParsePublicKey(string(data))
}

// ---------------------------------------------------------------------------
// Probe status heuristics, from the probe's own status files
// ---------------------------------------------------------------------------

type ProbeStatus struct {
	Running        bool
	PID            int
	StartedAt      time.Time
	UptimeSeconds  int64
	Restarts       int
	LastExit       string `json:",omitempty"`
	Registered     bool   // registration state file (reginit.vol) present
	Connected      bool   // Registered + ssh keepalive session to controller alive
	ControllerHost string `json:",omitempty"`
	ControllerPort string `json:",omitempty"`
	ProbeID        int    `json:",omitempty"`
	KeyExists      bool
	Fingerprint    string `json:",omitempty"`
	Version        string `json:",omitempty"`
}

// ParseControllerInfo extracts CONTROLLER_1_HOST/PORT from the probe's
// con_init_conf.txt ("KEY value" lines, see upstream reginit.sh).
func ParseControllerInfo(r io.Reader) (host string, port string) {
	scanner := bufio.NewScanner(r)
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		if len(fields) < 2 {
			continue
		}
		switch fields[0] {
		case "CONTROLLER_1_HOST":
			host = fields[1]
		case "CONTROLLER_1_PORT":
			port = fields[1]
		}
	}
	return host, port
}

// ParseProbeID extracts the numeric RIPE Atlas probe ID from the successful
// registration reply ("PROBE_ID <id>").
func ParseProbeID(r io.Reader) int {
	scanner := bufio.NewScanner(r)
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		if len(fields) < 2 || fields[0] != "PROBE_ID" {
			continue
		}
		id, err := strconv.Atoi(fields[1])
		if err == nil && id > 0 {
			return id
		}
	}
	return 0
}

func probeID() int {
	f, err := os.Open(StatusDir + "/reg_init_reply.txt")
	if err != nil {
		return 0
	}
	defer f.Close()
	return ParseProbeID(f)
}

// pidAlive reports whether the pid read from a probe .vol file is running.
func pidAlive(pid int) bool {
	if pid <= 0 {
		return false
	}
	return syscall.Kill(pid, 0) == nil
}

// readPidFile reads a pidfile written by the probe (ssh keepalive session).
func readPidFile(path string) int {
	data, err := os.ReadFile(path)
	if err != nil {
		return 0
	}
	pid := 0
	fmt.Sscanf(strings.TrimSpace(string(data)), "%d", &pid)
	return pid
}

func probeConnectionState() (registered bool, connected bool, host string, port string) {
	if _, err := os.Stat(StatusDir + "/reginit.vol"); err == nil {
		registered = true
	}
	if f, err := os.Open(StatusDir + "/con_init_conf.txt"); err == nil {
		host, port = ParseControllerInfo(f)
		f.Close()
	}
	if registered {
		connected = pidAlive(readPidFile(StatusDir + "/con_keep_pid.vol"))
	}
	return
}

func probeVersion() string {
	data, err := os.ReadFile(FirmwareVersFile)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(data))
}

// ---------------------------------------------------------------------------
// Log capture: ring buffer of sanitized lines + size-capped file on /state
// ---------------------------------------------------------------------------

// SanitizeLogLine strips control characters (keeping tabs) and redacts
// anything that looks like key material. Probe logs never should contain
// secrets, but the output is admin-visible so scrub defensively.
func SanitizeLogLine(line string) string {
	if strings.Contains(line, "PRIVATE KEY") {
		return "[redacted line containing key material]"
	}
	var b strings.Builder
	for _, r := range line {
		if r == '\t' || (r >= 0x20 && r != 0x7f) {
			b.WriteRune(r)
		}
	}
	s := b.String()
	if len(s) > 500 {
		s = s[:500]
	}
	return s
}

// LineRing is a fixed-capacity ring buffer of log lines.
type LineRing struct {
	mtx   sync.Mutex
	lines []string
	next  int
	full  bool
}

func NewLineRing(capacity int) *LineRing {
	return &LineRing{lines: make([]string, capacity)}
}

func (lr *LineRing) Add(line string) {
	lr.mtx.Lock()
	defer lr.mtx.Unlock()
	lr.lines[lr.next] = line
	lr.next = (lr.next + 1) % len(lr.lines)
	if lr.next == 0 {
		lr.full = true
	}
}

// Last returns up to n most recent lines, oldest first.
func (lr *LineRing) Last(n int) []string {
	lr.mtx.Lock()
	defer lr.mtx.Unlock()
	size := lr.next
	if lr.full {
		size = len(lr.lines)
	}
	if n > size {
		n = size
	}
	out := make([]string, 0, n)
	start := lr.next - n
	if start < 0 {
		start += len(lr.lines)
	}
	for i := 0; i < n; i++ {
		out = append(out, lr.lines[(start+i)%len(lr.lines)])
	}
	return out
}

// ---------------------------------------------------------------------------
// Supervisor: runs the probe as a child process group, restarts on exit
// ---------------------------------------------------------------------------

type Supervisor struct {
	mtx       sync.Mutex
	command   string
	cmd       *exec.Cmd
	startedAt time.Time
	restarts  int
	lastExit  string
	ring      *LineRing
	restartCh chan struct{}
}

func NewSupervisor(command string) *Supervisor {
	return &Supervisor{
		command:   command,
		ring:      NewLineRing(ringCapacityLines),
		restartCh: make(chan struct{}, 1),
	}
}

func (s *Supervisor) Start() {
	go s.loop()
}

func (s *Supervisor) logSink() io.WriteCloser {
	pr, pw := io.Pipe()
	go func() {
		var logFile *os.File
		if fi, err := os.Stat(ProbeLogFile); err == nil && fi.Size() > probeLogMaxBytes {
			os.Rename(ProbeLogFile, ProbeLogFile+".1")
		}
		logFile, err := os.OpenFile(ProbeLogFile, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0600)
		if err != nil {
			fmt.Println("[-] failed to open probe log file:", err)
		}
		scanner := bufio.NewScanner(pr)
		scanner.Buffer(make([]byte, 64*1024), 64*1024)
		for scanner.Scan() {
			line := SanitizeLogLine(scanner.Text())
			s.ring.Add(line)
			if logFile != nil {
				fmt.Fprintln(logFile, line)
			}
		}
		if logFile != nil {
			logFile.Close()
		}
	}()
	return pw
}

func (s *Supervisor) loop() {
	for {
		sink := s.logSink()
		cmd := exec.Command(s.command)
		cmd.Stdout = sink
		cmd.Stderr = sink
		// Own process group so ssh/perd/eperd/eooqd children can be
		// signalled together on stop/restart.
		cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}

		s.mtx.Lock()
		err := cmd.Start()
		if err == nil {
			s.cmd = cmd
			s.startedAt = time.Now()
		} else {
			s.cmd = nil
			s.lastExit = "start failed: " + err.Error()
		}
		s.mtx.Unlock()

		if err == nil {
			fmt.Println("[+] probe started, pid", cmd.Process.Pid)
			werr := cmd.Wait()
			s.mtx.Lock()
			s.cmd = nil
			s.restarts++
			if werr != nil {
				s.lastExit = werr.Error()
			} else {
				s.lastExit = "exited cleanly"
			}
			s.mtx.Unlock()
			fmt.Println("[-] probe exited:", s.lastExit)
			s.reapStragglers()
		} else {
			fmt.Println("[-] probe start failed:", err)
		}
		sink.Close()

		// Fast restart when requested via the API, back off otherwise.
		select {
		case <-s.restartCh:
		case <-time.After(10 * time.Second):
		}
	}
}

// reapStragglers kills probe daemons that may have detached from the process
// group (mirrors upstream's ExecStop killall). Fixed argv, no user input.
func (s *Supervisor) reapStragglers() {
	exec.Command("killall", "-9", "-q", "telnetd", "perd", "eperd", "eooqd", "ssh").Run()
}

// Restart terminates the probe process group; the supervise loop restarts it.
func (s *Supervisor) Restart() error {
	s.mtx.Lock()
	cmd := s.cmd
	s.mtx.Unlock()

	// Request a fast restart cycle.
	select {
	case s.restartCh <- struct{}{}:
	default:
	}

	if cmd == nil || cmd.Process == nil {
		return nil // not running; loop will start it
	}
	pgid := cmd.Process.Pid
	syscall.Kill(-pgid, syscall.SIGTERM)
	for i := 0; i < 50; i++ {
		s.mtx.Lock()
		running := s.cmd != nil
		s.mtx.Unlock()
		if !running {
			return nil
		}
		time.Sleep(100 * time.Millisecond)
	}
	syscall.Kill(-pgid, syscall.SIGKILL)
	return nil
}

func (s *Supervisor) Logs(n int) []string {
	return s.ring.Last(n)
}

func (s *Supervisor) Status() ProbeStatus {
	s.mtx.Lock()
	st := ProbeStatus{
		Restarts: s.restarts,
		LastExit: s.lastExit,
	}
	if s.cmd != nil && s.cmd.Process != nil {
		st.Running = true
		st.PID = s.cmd.Process.Pid
		st.StartedAt = s.startedAt
		st.UptimeSeconds = int64(time.Since(s.startedAt).Seconds())
	}
	s.mtx.Unlock()

	st.Registered, st.Connected, st.ControllerHost, st.ControllerPort = probeConnectionState()
	st.ProbeID = probeID()
	st.Version = probeVersion()
	if key, err := ReadPublicKey(ProbeKeyPubFile); err == nil {
		st.KeyExists = true
		st.Fingerprint = key.Fingerprint
	}
	return st
}
