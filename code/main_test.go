package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestPluginListenerUsesTemplateSocket(t *testing.T) {
	dir, err := os.MkdirTemp("/tmp", "atlas-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	path := filepath.Join(dir, "plugin.sock")
	t.Setenv("SPR_KRUN_PLUGIN_SOCKET", path)
	listener, err := pluginListener()
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("plugin socket was not created: %v", err)
	}
}

func TestPluginListenerRejectsRelativeTemplateSocket(t *testing.T) {
	t.Setenv("SPR_KRUN_PLUGIN_SOCKET", "plugin.sock")
	if _, err := pluginListener(); err == nil {
		t.Fatal("pluginListener accepted a relative template socket")
	}
}
