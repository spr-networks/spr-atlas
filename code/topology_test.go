package main

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestBuildTopologyNoController(t *testing.T) {
	topo := BuildTopology("", false)
	if len(topo.Nodes) != 1 {
		t.Fatalf("expected root anchor only, got %d nodes", len(topo.Nodes))
	}
	root := topo.Nodes[0]
	if root.ID != "root" || root.ConnType != "atlas" || !root.Online {
		t.Errorf("bad root anchor: %+v", root)
	}
	if topo.Edges == nil || len(topo.Edges) != 0 {
		t.Errorf("expected empty (non-nil) edge list, got %v", topo.Edges)
	}
}

func TestBuildTopologyController(t *testing.T) {
	topo := BuildTopology("ctr-ams01.atlas.ripe.net", true)
	if len(topo.Nodes) != 2 || len(topo.Edges) != 1 {
		t.Fatalf("expected root+controller and one edge, got %d nodes %d edges",
			len(topo.Nodes), len(topo.Edges))
	}
	ctrl := topo.Nodes[1]
	if ctrl.ID != "controller" || ctrl.Kind != "controller" {
		t.Errorf("bad controller node identity: %+v", ctrl)
	}
	if ctrl.Name != "ctr-ams01.atlas.ripe.net" {
		t.Errorf("controller name = %q", ctrl.Name)
	}
	if !ctrl.Online {
		t.Error("controller should be online when connected")
	}
	edge := topo.Edges[0]
	if edge.From != "root" || edge.To != "controller" || edge.Layer != "wan" {
		t.Errorf("bad edge: %+v", edge)
	}
}

func TestBuildTopologyControllerOffline(t *testing.T) {
	// Registered (controller assigned) but keepalive session down.
	topo := BuildTopology("ctr-ams01.atlas.ripe.net", false)
	if len(topo.Nodes) != 2 {
		t.Fatalf("expected 2 nodes, got %d", len(topo.Nodes))
	}
	if topo.Nodes[1].Online {
		t.Error("controller must be offline when not connected")
	}
	if !topo.Nodes[0].Online {
		t.Error("root anchor is always online")
	}
}

func TestTopologyJSONShape(t *testing.T) {
	data, err := json.Marshal(BuildTopology("", false))
	if err != nil {
		t.Fatal(err)
	}
	s := string(data)
	// Host-side contract: Edges must encode as [] (not null) and empty
	// optional fields (IP, ConnType-on-edges-absent, ...) must be omitted.
	if !strings.Contains(s, `"Edges":[]`) {
		t.Errorf("empty graph must serialize Edges as []: %s", s)
	}
	if strings.Contains(s, `"IP"`) {
		t.Errorf("empty IP must be omitted: %s", s)
	}
}
