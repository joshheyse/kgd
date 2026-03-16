package engine

import (
	"context"
	"fmt"
	"log/slog"
	"sync/atomic"

	"github.com/joshheyse/kgd/internal/allocator"
	"github.com/joshheyse/kgd/internal/graphics"
	"github.com/joshheyse/kgd/internal/protocol"
	"github.com/joshheyse/kgd/internal/tty"
	"github.com/joshheyse/kgd/internal/upload"
)

// Engine is the PlacementEngine — the single goroutine that owns all
// mutable placement state. All other goroutines communicate with it via
// the Events channel.
type Engine struct {
	Events  chan Event
	writer  *tty.Writer
	gfx     graphics.Graphics
	idAlloc *allocator.IDAllocator
	cache   *upload.Cache

	// Placement state (only accessed from the Run goroutine)
	placements    map[uint32]*Placement
	clientImages  map[string]map[uint32]uint32 // clientID → handle → kittyImgID
	panes         map[string]PaneGeometry
	wins          map[int]WinGeometry
	nextPlacement atomic.Uint32

	// Terminal state
	termSize   tty.WinSize
	termColors tty.TermColors

	// Notifications
	notifier Notifier

	// Stop function for graceful shutdown
	stopFunc context.CancelFunc
}

// New creates a new PlacementEngine.
func New(writer *tty.Writer, gfx graphics.Graphics, idAlloc *allocator.IDAllocator, cache *upload.Cache) *Engine {
	return &Engine{
		Events:       make(chan Event, 256),
		writer:       writer,
		gfx:          gfx,
		idAlloc:      idAlloc,
		cache:        cache,
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
	defer e.drain()

	for {
		select {
		case <-ctx.Done():
			return
		case sz := <-e.writer.Size:
			e.termSize = sz
			slog.Debug("engine received terminal size", "rows", sz.Rows, "cols", sz.Cols)
			e.recomputePlacements()
			if e.notifier != nil {
				cellW, cellH := 0, 0
				if sz.Cols > 0 {
					cellW = int(sz.XPixel) / int(sz.Cols)
				}
				if sz.Rows > 0 {
					cellH = int(sz.YPixel) / int(sz.Rows)
				}
				e.notifier.NotifyAll(protocol.NotifyTopologyChanged, protocol.TopologyChangedParams{
					Cols: int(sz.Cols), Rows: int(sz.Rows),
					CellWidth: cellW, CellHeight: cellH,
				})
			}
		case colors := <-e.writer.Colors:
			e.termColors = colors
			slog.Debug("engine received terminal colors")
			if e.notifier != nil {
				e.notifier.NotifyAll(protocol.NotifyThemeChanged, protocol.ThemeChangedParams{
					FG: protocol.Color{R: colors.FG.R, G: colors.FG.G, B: colors.FG.B},
					BG: protocol.Color{R: colors.BG.R, G: colors.BG.G, B: colors.BG.B},
				})
			}
		case ev := <-e.Events:
			e.handle(ev)
		}
	}
}

// SetStopFunc sets the function used by StopRequest to cancel the daemon context.
func (e *Engine) SetStopFunc(f context.CancelFunc) {
	e.stopFunc = f
}

// SetNotifier sets the notifier used to send notifications to clients.
func (e *Engine) SetNotifier(n Notifier) {
	e.notifier = n
}

// ClientDisconnected notifies the engine that a client has disconnected.
// Safe to call from any goroutine.
func (e *Engine) ClientDisconnected(clientID string) {
	e.Events <- ClientDisconnect{ClientID: clientID}
}

func (e *Engine) handle(ev Event) {
	switch ev := ev.(type) {
	case HelloRequest:
		e.handleHello(ev)
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
	case UpdatePanes:
		e.handleUpdatePanes(ev)
	case ClientDisconnect:
		e.handleClientDisconnect(ev)
	case ListRequest:
		e.handleList(ev)
	case StatusRequest:
		e.handleStatus(ev)
	case StopRequest:
		e.handleStop()
	default:
		slog.Warn("unknown event type", "event", ev)
	}
}

func (e *Engine) handleHello(req HelloRequest) {
	cellW, cellH := 0, 0
	if e.termSize.Cols > 0 {
		cellW = int(e.termSize.XPixel) / int(e.termSize.Cols)
	}
	if e.termSize.Rows > 0 {
		cellH = int(e.termSize.YPixel) / int(e.termSize.Rows)
	}

	req.Reply <- HelloReply{
		Result: protocol.HelloResult{
			ClientID:   req.ClientID,
			Cols:       int(e.termSize.Cols),
			Rows:       int(e.termSize.Rows),
			CellWidth:  cellW,
			CellHeight: cellH,
			InTmux:     e.writer.InTmux(),
			FG:         protocol.Color{R: e.termColors.FG.R, G: e.termColors.FG.G, B: e.termColors.FG.B},
			BG:         protocol.Color{R: e.termColors.BG.R, G: e.termColors.BG.G, B: e.termColors.BG.B},
		},
	}
	slog.Info("client hello", "client", req.ClientID, "type", req.Params.ClientType, "label", req.Params.Label)
}

func (e *Engine) handlePlace(req PlaceRequest) {
	images, ok := e.clientImages[req.ClientID]
	if !ok {
		req.Reply <- PlaceReply{Err: fmt.Errorf("no images for client")}
		return
	}
	kittyID, ok := images[req.Params.Handle]
	if !ok {
		req.Reply <- PlaceReply{Err: fmt.Errorf("unknown handle %d", req.Params.Handle)}
		return
	}

	id := e.nextPlacement.Add(1)
	p := &Placement{
		ID:          id,
		ClientID:    req.ClientID,
		ImageHandle: req.Params.Handle,
		KittyImgID:  kittyID,
		Anchor:      req.Params.Anchor,
		Width:       req.Params.Width,
		Height:      req.Params.Height,
		SrcX:        req.Params.SrcX,
		SrcY:        req.Params.SrcY,
		SrcW:        req.Params.SrcW,
		SrcH:        req.Params.SrcH,
		ZIndex:      req.Params.ZIndex,
	}

	row, col, visible := p.ScreenPos(e.panes, e.wins)
	p.TermRow = row
	p.TermCol = col
	p.Visible = visible

	e.placements[id] = p

	if visible && e.gfx != nil {
		if err := e.gfx.Place(kittyID, id, row, col, p); err != nil {
			slog.Error("failed to place image", "error", err, "placement", id)
		} else {
			p.Rendered = true
		}
	}

	req.Reply <- PlaceReply{PlacementID: id}
	slog.Debug("placement created", "id", id, "client", req.ClientID, "visible", visible)
}

func (e *Engine) handleUnplace(req UnplaceRequest) {
	p, ok := e.placements[req.Params.PlacementID]
	if !ok {
		return
	}
	if p.ClientID != req.ClientID {
		return
	}

	if p.Rendered && e.gfx != nil {
		if err := e.gfx.Delete(p.KittyImgID, p.ID, false); err != nil {
			slog.Error("failed to delete placement", "error", err, "placement", p.ID)
		}
	}
	delete(e.placements, req.Params.PlacementID)
	slog.Debug("placement removed", "id", req.Params.PlacementID)
}

func (e *Engine) handleUnplaceAll(req UnplaceAllRequest) {
	for id, p := range e.placements {
		if p.ClientID == req.ClientID {
			if p.Rendered && e.gfx != nil {
				if err := e.gfx.Delete(p.KittyImgID, p.ID, false); err != nil {
					slog.Error("failed to delete placement", "error", err, "placement", p.ID)
				}
			}
			delete(e.placements, id)
		}
	}
	slog.Debug("all placements removed", "client", req.ClientID)
}

func (e *Engine) handleUpload(req UploadRequest) {
	// Content-addressed cache lookup
	if kittyID, found := e.cache.Lookup(req.Params.Data); found {
		handle := e.assignHandle(req.ClientID, kittyID)
		e.cache.Store(req.Params.Data, kittyID)
		req.Reply <- UploadReply{Handle: handle}
		slog.Debug("upload cache hit", "client", req.ClientID, "handle", handle, "kittyID", kittyID)
		return
	}

	kittyID := e.idAlloc.Next()

	if e.gfx != nil {
		if err := e.gfx.Transmit(kittyID, req.Params.Data, req.Params.Format, req.Params.Width, req.Params.Height); err != nil {
			req.Reply <- UploadReply{Err: fmt.Errorf("transmit: %w", err)}
			return
		}
	}

	evicted := e.cache.Store(req.Params.Data, kittyID)
	for _, eid := range evicted {
		if e.gfx != nil {
			if err := e.gfx.Delete(eid, 0, true); err != nil {
				slog.Error("failed to free evicted image", "error", err, "kittyID", eid)
			}
		}
		// Notify clients whose handles point to the evicted image
		e.notifyEviction(eid)
	}

	handle := e.assignHandle(req.ClientID, kittyID)
	req.Reply <- UploadReply{Handle: handle}
	slog.Debug("upload complete", "client", req.ClientID, "handle", handle, "kittyID", kittyID)
}

func (e *Engine) handleFree(req FreeRequest) {
	images, ok := e.clientImages[req.ClientID]
	if !ok {
		return
	}
	kittyID, ok := images[req.Handle]
	if !ok {
		return
	}
	delete(images, req.Handle)
	e.cache.Release(kittyID)
	slog.Debug("image freed", "client", req.ClientID, "handle", req.Handle)
}

func (e *Engine) handleScrollUpdate(ev ScrollUpdate) {
	if win, ok := e.wins[ev.Params.WinID]; ok {
		win.ScrollTop = ev.Params.ScrollTop
		e.wins[ev.Params.WinID] = win
		e.recomputePlacements()
	}
}

func (e *Engine) handleRegisterWin(ev RegisterWin) {
	e.wins[ev.Params.WinID] = WinGeometry{
		WinID:     ev.Params.WinID,
		ClientID:  ev.ClientID,
		PaneID:    ev.Params.PaneID,
		Top:       ev.Params.Top,
		Left:      ev.Params.Left,
		Width:     ev.Params.Width,
		Height:    ev.Params.Height,
		ScrollTop: ev.Params.ScrollTop,
	}
	e.recomputePlacements()
	slog.Debug("window registered", "win_id", ev.Params.WinID)
}

func (e *Engine) handleUnregisterWin(ev UnregisterWin) {
	delete(e.wins, ev.WinID)
	e.recomputePlacements()
	slog.Debug("window unregistered", "win_id", ev.WinID)
}

func (e *Engine) handleUpdatePanes(ev UpdatePanes) {
	e.panes = make(map[string]PaneGeometry, len(ev.Panes))
	for _, p := range ev.Panes {
		e.panes[p.ID] = p
	}
	e.recomputePlacements()
	slog.Debug("pane topology updated", "panes", len(ev.Panes))
}

func (e *Engine) handleClientDisconnect(ev ClientDisconnect) {
	for id, p := range e.placements {
		if p.ClientID == ev.ClientID {
			if p.Rendered && e.gfx != nil {
				if err := e.gfx.Delete(p.KittyImgID, p.ID, false); err != nil {
					slog.Error("failed to delete placement on disconnect", "error", err)
				}
			}
			delete(e.placements, id)
		}
	}
	if images, ok := e.clientImages[ev.ClientID]; ok {
		for _, kittyID := range images {
			e.cache.Release(kittyID)
		}
	}
	delete(e.clientImages, ev.ClientID)
	// Clean up nvim window registrations for this client
	for winID, win := range e.wins {
		if win.ClientID == ev.ClientID {
			delete(e.wins, winID)
		}
	}
	slog.Info("client cleanup complete", "client", ev.ClientID)
}

func (e *Engine) handleList(req ListRequest) {
	var placements []protocol.PlacementInfo
	for _, p := range e.placements {
		placements = append(placements, protocol.PlacementInfo{
			PlacementID: p.ID,
			ClientID:    p.ClientID,
			Handle:      p.ImageHandle,
			Visible:     p.Visible,
			Row:         p.TermRow,
			Col:         p.TermCol,
		})
	}
	req.Reply <- ListReply{
		Result: protocol.ListResult{Placements: placements},
	}
}

func (e *Engine) handleStatus(req StatusRequest) {
	// Count unique kitty image IDs across all clients
	uniqueImages := make(map[uint32]struct{})
	for _, images := range e.clientImages {
		for _, kittyID := range images {
			uniqueImages[kittyID] = struct{}{}
		}
	}

	req.Reply <- StatusReply{
		Result: protocol.StatusResult{
			Clients:    len(e.clientImages),
			Placements: len(e.placements),
			Images:     len(uniqueImages),
			Cols:       int(e.termSize.Cols),
			Rows:       int(e.termSize.Rows),
		},
	}
}

func (e *Engine) handleStop() {
	if e.stopFunc != nil {
		slog.Info("stop requested, shutting down")
		e.stopFunc()
	}
}

// drain empties the event channel on shutdown, replying to any pending requests
// with errors so client goroutines don't block.
// NOTE: Any new Event type with a Reply channel must be handled here.
func (e *Engine) drain() {
	for {
		select {
		case ev := <-e.Events:
			switch ev := ev.(type) {
			case HelloRequest:
				ev.Reply <- HelloReply{Err: fmt.Errorf("shutting down")}
			case PlaceRequest:
				ev.Reply <- PlaceReply{Err: fmt.Errorf("shutting down")}
			case UploadRequest:
				ev.Reply <- UploadReply{Err: fmt.Errorf("shutting down")}
			case ListRequest:
				ev.Reply <- ListReply{}
			case StatusRequest:
				ev.Reply <- StatusReply{}
			default:
				// Fire-and-forget events — discard
			}
		default:
			return
		}
	}
}

// assignHandle creates a client-local handle mapping to a kitty image ID.
func (e *Engine) assignHandle(clientID string, kittyID uint32) uint32 {
	images, ok := e.clientImages[clientID]
	if !ok {
		images = make(map[uint32]uint32)
		e.clientImages[clientID] = images
	}
	var handle uint32
	for handle = 1; ; handle++ {
		if _, exists := images[handle]; !exists {
			break
		}
	}
	images[handle] = kittyID
	return handle
}

// notifyEviction finds clients whose handles reference an evicted kitty image ID
// and notifies them.
func (e *Engine) notifyEviction(kittyID uint32) {
	if e.notifier == nil {
		return
	}
	for clientID, images := range e.clientImages {
		for handle, kid := range images {
			if kid == kittyID {
				e.notifier.NotifyClient(clientID, protocol.NotifyEvicted, protocol.EvictedParams{Handle: handle})
			}
		}
	}
}

// recomputePlacements re-resolves all placement positions and updates visibility.
// Place/Delete operations are batched into a single atomic write to prevent tearing.
func (e *Engine) recomputePlacements() {
	if e.gfx != nil {
		e.gfx.BeginBatch()
		defer e.gfx.FlushBatch()
	}

	for _, p := range e.placements {
		row, col, visible := p.ScreenPos(e.panes, e.wins)
		wasVisible := p.Visible
		wasRendered := p.Rendered
		oldRow := p.TermRow
		oldCol := p.TermCol

		p.TermRow = row
		p.TermCol = col
		p.Visible = visible

		if e.gfx == nil {
			continue
		}

		if visible && !wasRendered {
			if err := e.gfx.Place(p.KittyImgID, p.ID, row, col, p); err != nil {
				slog.Error("failed to place image during recompute", "error", err)
			} else {
				p.Rendered = true
			}
		} else if !visible && wasRendered {
			if err := e.gfx.Delete(p.KittyImgID, p.ID, false); err != nil {
				slog.Error("failed to delete image during recompute", "error", err)
			}
			p.Rendered = false
		} else if visible && wasRendered && (row != oldRow || col != oldCol) {
			// Position changed — delete and re-place
			if err := e.gfx.Delete(p.KittyImgID, p.ID, false); err != nil {
				slog.Error("failed to delete moved placement", "error", err)
			}
			if err := e.gfx.Place(p.KittyImgID, p.ID, row, col, p); err != nil {
				slog.Error("failed to re-place moved placement", "error", err)
			}
		}

		// Notify on visibility change
		if visible != wasVisible && e.notifier != nil {
			e.notifier.NotifyClient(p.ClientID, protocol.NotifyVisibilityChanged,
				protocol.VisibilityChangedParams{PlacementID: p.ID, Visible: visible})
		}
	}
}
