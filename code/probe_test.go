package main

import (
	"os"
	"strings"
	"testing"
)

// A fake key blob for tests only (valid base64, not a real key).
const testPubKey = "ssh-rsa dGVzdC1zc2gta2V5LWJsb2ItMDEyMzQ1Njc4OQ== spr-atlas-router"

func TestParsePublicKeyValid(t *testing.T) {
	info, err := ParsePublicKey(testPubKey + "\n")
	if err != nil {
		t.Fatalf("expected valid key, got error: %v", err)
	}
	if !info.Exists {
		t.Error("expected Exists=true")
	}
	if info.PublicKey != testPubKey {
		t.Errorf("normalized key mismatch: %q", info.PublicKey)
	}
	if !strings.HasPrefix(info.Fingerprint, "SHA256:") {
		t.Errorf("expected SHA256 fingerprint, got %q", info.Fingerprint)
	}
	if info.Comment != "spr-atlas-router" {
		t.Errorf("expected comment, got %q", info.Comment)
	}
}

func TestParsePublicKeyRejectsPrivate(t *testing.T) {
	priv := "-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n-----END OPENSSH PRIVATE KEY-----"
	if _, err := ParsePublicKey(priv); err == nil {
		t.Fatal("expected private key material to be rejected")
	}
}

func TestParsePublicKeyRejectsGarbage(t *testing.T) {
	cases := []string{
		"",
		"not-a-key",
		"ssh-rsa",                       // missing blob
		"ssh-dss AAAAB3NzaC1kc3M robot", // disallowed type
		"ssh-rsa !!!notbase64!!! c",     // bad base64
		"ssh-rsa AAAA\nssh-rsa AAAA",    // multiple lines
	}
	for _, c := range cases {
		if _, err := ParsePublicKey(c); err == nil {
			t.Errorf("expected error for %q", c)
		}
	}
}

func TestParseControllerInfo(t *testing.T) {
	conf := `CONTROLLER_1_HOST ctr-ams01.atlas.ripe.net
CONTROLLER_1_PORT 443
REREG_TIMER 1767139200
FIRMWARE_APPS_VERSION 5120
bogus line without keyword match
`
	host, port := ParseControllerInfo(strings.NewReader(conf))
	if host != "ctr-ams01.atlas.ripe.net" {
		t.Errorf("host = %q", host)
	}
	if port != "443" {
		t.Errorf("port = %q", port)
	}
}

func TestParseControllerInfoEmpty(t *testing.T) {
	host, port := ParseControllerInfo(strings.NewReader(""))
	if host != "" || port != "" {
		t.Errorf("expected empty, got %q %q", host, port)
	}
}

func TestParseProbeID(t *testing.T) {
	reply := `CONTROLLER_1_HOST ctr-ams01.atlas.ripe.net
PROBE_ID 1016551
CONTROLLER_1_PORT 443
`
	if got := ParseProbeID(strings.NewReader(reply)); got != 1016551 {
		t.Fatalf("probe ID = %d, want 1016551", got)
	}
}

func TestParseProbeIDRejectsInvalidValues(t *testing.T) {
	for _, reply := range []string{
		"",
		"PROBE_ID\n",
		"PROBE_ID nope\n",
		"PROBE_ID 0\n",
		"PROBE_ID -1\n",
	} {
		if got := ParseProbeID(strings.NewReader(reply)); got != 0 {
			t.Errorf("ParseProbeID(%q) = %d, want 0", reply, got)
		}
	}
}

func TestStatusIncludesProbeID(t *testing.T) {
	originalStatusDir := StatusDir
	StatusDir = t.TempDir()
	t.Cleanup(func() { StatusDir = originalStatusDir })

	if err := os.WriteFile(StatusDir+"/reg_init_reply.txt", []byte("PROBE_ID 1016551\n"), 0600); err != nil {
		t.Fatal(err)
	}

	status := NewSupervisor("unused").Status()
	if status.ProbeID != 1016551 {
		t.Fatalf("status probe ID = %d, want 1016551", status.ProbeID)
	}
}

func TestSanitizeLogLine(t *testing.T) {
	if got := SanitizeLogLine("plain line"); got != "plain line" {
		t.Errorf("got %q", got)
	}
	if got := SanitizeLogLine("colored \x1b[31mred\x1b[0m end"); strings.ContainsRune(got, 0x1b) {
		t.Errorf("control chars not stripped: %q", got)
	}
	if got := SanitizeLogLine("keep\ttabs"); got != "keep\ttabs" {
		t.Errorf("tab was stripped: %q", got)
	}
	if got := SanitizeLogLine("-----BEGIN RSA PRIVATE KEY-----"); strings.Contains(got, "BEGIN") {
		t.Errorf("private key material not redacted: %q", got)
	}
	long := strings.Repeat("a", 2000)
	if got := SanitizeLogLine(long); len(got) > 500 {
		t.Errorf("long line not truncated: %d", len(got))
	}
}

func TestLineRing(t *testing.T) {
	lr := NewLineRing(3)
	if got := lr.Last(10); len(got) != 0 {
		t.Errorf("empty ring should return no lines, got %v", got)
	}
	lr.Add("1")
	lr.Add("2")
	if got := lr.Last(10); len(got) != 2 || got[0] != "1" || got[1] != "2" {
		t.Errorf("got %v", got)
	}
	lr.Add("3")
	lr.Add("4") // wraps, evicts "1"
	got := lr.Last(10)
	if len(got) != 3 || got[0] != "2" || got[2] != "4" {
		t.Errorf("got %v", got)
	}
	if got := lr.Last(1); len(got) != 1 || got[0] != "4" {
		t.Errorf("got %v", got)
	}
}
