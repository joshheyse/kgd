package engine

import (
	"context"
	"log/slog"
	"sync/atomic"

	"github.com/joshheyse/kgd/internal/tty"
)

// Engine is the PlacementEngine — the single goroutine that owns all
// mutable placement state. All other goroutines communicate with it via
// the Events channel.
type Engine struct {
	Events chan Event
	writer *tty.Writer

	// Placement state (only accessed from the Run goroutine)
	placements    map[uint32]*Placement
	clientImages  map[string]map[uint32]uint32 // clientID → handle → kittyImgID
	panes         map[string]PaneGeometry
	wins          map[int]WinGeometry
	nextPlacement atomic.Uint32
}

// New creates a new PlacementEngine.
func New(writer *tty.Writer) *Engine {
	return &Engine{
		Events:       make(chan Event, 256),
		writer:       writer,
		placements:   make(map[uint32]*Placement),
		clientImages: make(map[string]map[uint32]uint32),
		panes:        make(map[string]PaneGeometry),
		wins:         make(map[int]WinGeometry),
	}
}

// Run processes events until ctx is cancelled. Must be called as a goroutine.
func (e *Engine) Run(ctx context.Context) {
	slog.Info("placement engine started")
	defer slog.Info("placement engine stopped")

	for {
		select {
		case <-ctx.Done():
			return
		case ev := <-e.Events:
			e.handle(ev)
		}
	}
}

// ClientDisconnected notifies the engine that a client has disconnected.
// Safe to call from any goroutine.
func (e *Engine) ClientDisconnected(clientID string) {
	e.Events <- ClientDisconnect{ClientID: clientID}
}

func (e *Engine) handle(ev Event) {
	switch ev := ev.(type) {
	case PlaceRequest:
		e.handlePlace(ev)
	case UnplaceRequest:
		e.handleUnplace(ev)
	case UnplaceAllRequest:
		e.handleUnplaceAll(ev)
	case UploadRequest:
		e.handleUpload(ev)
	case FreeRequest:
		e.handleFree(ev)
	case ScrollUpdate:
		e.handleScrollUpdate(ev)
	case RegisterWin:
		e.handleRegisterWin(ev)
	case UnregisterWin:
		e.handleUnregisterWin(ev)
	case TopologyEvent:
		e.handleTopology(ev)
	case ClientDisconnect:
		e.handleClientDisconnect(ev)
	default:
		slog.Warn("unknown event type", "event", ev)
	}
}

func (e *Engine) handlePlace(req PlaceRequest) {
	id := e.nextPlacement.Add(1)
	p := &Placement{
		ID:          id,
		ClientID:    req.ClientID,
		ImageHandle: req.Params.Handle,
		Anchor:      req.Params.Anchor,
		Width:       req.Params.Width,
		Height:      req.Params.Height,
		SrcX:        req.Params.SrcX,
		SrcY:        req.Params.SrcY,
		SrcW:        req.Params.SrcW,
		SrcH:        req.Params.SrcH,
		ZIndex:      req.Params.ZIndex,
	}
	e.placements[id] = p
	req.Reply <- PlaceReply{PlacementID: id}

	// TODO: resolve coordinates, render to TTY
	slog.Debug("placement created", "id", id, "client", req.ClientID)
}

func (e *Engine) handleUnplace(req UnplaceRequest) {
	if p, ok := e.placements[req.Params.PlacementID]; ok {
		if p.ClientID == req.ClientID {
			delete(e.placements, req.Params.PlacementID)
			// TODO: send kitty delete to TTY
			slog.Debug("placement removed", "id", req.Params.PlacementID)
		}
	}
}

func (e *Engine) handleUnplaceAll(req UnplaceAllRequest) {
	for id, p := range e.placements {
		if p.ClientID == req.ClientID {
			delete(e.placements, id)
		}
	}
	// TODO: send kitty deletes to TTY
	slog.Debug("all placements removed", "client", req.ClientID)
}

func (e *Engine) handleUpload(req UploadRequest) {
	// TODO: content-addressed cache, kitty transmit
	req.Reply <- UploadReply{Handle: 0, Err: nil}
}

func (e *Engine) handleFree(req FreeRequest) {
	// TODO: release image from cache
	slog.Debug("image freed", "client", req.ClientID, "handle", req.Handle)
}

func (e *Engine) handleScrollUpdate(ev ScrollUpdate) {
	if win, ok := e.wins[ev.Params.WinID]; ok {
		win.ScrollTop = ev.Params.ScrollTop
		e.wins[ev.Params.WinID] = win
		// TODO: recompute visibility for placements in this window
	}
}

func (e *Engine) handleRegisterWin(ev RegisterWin) {
	e.wins[ev.Params.WinID] = WinGeometry{
		WinID:     ev.Params.WinID,
		PaneID:    ev.Params.PaneID,
		Top:       ev.Params.Top,
		Left:      ev.Params.Left,
		Width:     ev.Params.Width,
		Height:    ev.Params.Height,
		ScrollTop: ev.Params.ScrollTop,
	}
	slog.Debug("window registered", "win_id", ev.Params.WinID)
}

func (e *Engine) handleUnregisterWin(ev UnregisterWin) {
	delete(e.wins, ev.WinID)
	slog.Debug("window unregistered", "win_id", ev.WinID)
}

func (e *Engine) handleTopology(_ TopologyEvent) {
	// TODO: recompute all placement positions and visibility
	slog.Debug("topology changed, recomputing placements")
}

func (e *Engine) handleClientDisconnect(ev ClientDisconnect) {
	// Remove all placements for this client
	for id, p := range e.placements {
		if p.ClientID == ev.ClientID {
			delete(e.placements, id)
		}
	}
	// Remove client image mappings
	delete(e.clientImages, ev.ClientID)
	// TODO: free unreferenced images from cache
	slog.Info("client cleanup complete", "client", ev.ClientID)
}
