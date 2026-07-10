package main

import "net/http"

// Topology contract shared with the SPR host (mirrors spr-tailscale): the
// host merges this graph into the router topology view at the "root" node.

type TopoNode struct {
	ID       string
	Kind     string
	Name     string
	IP       string `json:",omitempty"`
	ConnType string `json:",omitempty"`
	Online   bool
}

type TopoEdge struct {
	From  string
	To    string
	Layer string
	Kind  string
}

type Topology struct {
	Nodes []TopoNode
	Edges []TopoEdge
}

// BuildTopology renders the probe's single upstream relationship: the SPR
// host (root anchor) and, once registration has assigned one, the RIPE Atlas
// controller the probe keeps an outbound ssh session to. No controller known
// yet (unregistered, or the probe daemon is down) -> just the root anchor.
func BuildTopology(controllerHost string, connected bool) Topology {
	topo := Topology{
		Nodes: []TopoNode{{ID: "root", ConnType: "atlas", Online: true}},
		Edges: []TopoEdge{},
	}
	if controllerHost == "" {
		return topo
	}
	topo.Nodes = append(topo.Nodes, TopoNode{
		ID:       "controller",
		Kind:     "controller",
		Name:     controllerHost,
		ConnType: "atlas",
		Online:   connected,
	})
	topo.Edges = append(topo.Edges, TopoEdge{
		From:  "root",
		To:    "controller",
		Layer: "wan",
		Kind:  "ssh",
	})
	return topo
}

// handleGetTopology serves GET /topology from the probe's live state files.
func handleGetTopology(w http.ResponseWriter, r *http.Request) {
	_, connected, host, _ := probeConnectionState()
	jsonResponse(w, BuildTopology(host, connected))
}
