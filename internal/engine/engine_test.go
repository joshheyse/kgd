package engine

import (
	"context"
	"sync"
	"testing"
	"time"

	"github.com/joshheyse/kgd/internal/allocator"
	"github.com/joshheyse/kgd/internal/graphics"
	"github.com/joshheyse/kgd/internal/protocol"
	"github.com/joshheyse/kgd/internal/tty"
	"github.com/joshheyse/kgd/internal/upload"
)

// mockGraphics records all graphics operations for testing.
type mockGraphics struct {
	mu        sync.Mutex
	transmits []transmitCall
	places    []placeCall
	deletes   []deleteCall
}

type transmitCall struct {
	ID     uint32
	Format string
	Width  int
	Height int
}

type placeCall struct {
	ImageID     uint32
	PlacementID uint32
	Row, Col    int
}

type deleteCall struct {
	ImageID     uint32
	PlacementID uint32
	Free        bool
}

func (m *mockGraphics) Transmit(id uint32, data []byte, format string, width, height int) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.transmits = append(m.transmits, transmitCall{ID: id, Format: format, Width: width, Height: height})
	return nil
}

func (m *mockGraphics) Place(imageID, placementID uint32, row, col int, p graphics.PlacementInfo) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.places = append(m.places, placeCall{ImageID: imageID, PlacementID: placementID, Row: row, Col: col})
	return nil
}

func (m *mockGraphics) Delete(imageID, placementID uint32, free bool) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.deletes = append(m.deletes, deleteCall{ImageID: imageID, PlacementID: placementID, Free: free})
	return nil
}

func (m *mockGraphics) BeginBatch() {}
func (m *mockGraphics) FlushBatch() {}

func testEngine(t *testing.T, gfx graphics.Graphics) (*Engine, context.CancelFunc) {
	t.Helper()
	w := &tty.Writer{
		Writes: make(chan []byte, 64),
		Size:   make(chan tty.WinSize, 4),
		Colors: make(chan tty.TermColors, 2),
	}
	idAlloc := allocator.New()
	cache := upload.NewCache(256)
	eng := New(w, gfx, idAlloc, cache)
	ctx, cancel := context.WithCancel(context.Background())
	go eng.Run(ctx)
	return eng, cancel
}

func sendUpload(t *testing.T, eng *Engine, clientID string, data []byte) uint32 {
	t.Helper()
	reply := make(chan UploadReply, 1)
	eng.Events <- UploadRequest{
		ClientID: clientID,
		Params:   protocol.UploadParams{Data: data, Format: "png", Width: 10, Height: 10},
		Reply:    reply,
	}
	select {
	case r := <-reply:
		if r.Err != nil {
			t.Fatalf("upload error: %v", r.Err)
		}
		return r.Handle
	case <-time.After(2 * time.Second):
		t.Fatal("upload timed out")
		return 0
	}
}

func TestUploadTriggersTransmit(t *testing.T) {
	gfx := &mockGraphics{}
	eng, cancel := testEngine(t, gfx)
	defer cancel()

	sendUpload(t, eng, "client1", []byte("image-data"))

	time.Sleep(50 * time.Millisecond) // let engine process
	gfx.mu.Lock()
	defer gfx.mu.Unlock()
	if len(gfx.transmits) != 1 {
		t.Fatalf("expected 1 transmit, got %d", len(gfx.transmits))
	}
	if gfx.transmits[0].Format != "png" {
		t.Errorf("expected png format, got %s", gfx.transmits[0].Format)
	}
}

func TestUploadCacheHitSkipsTransmit(t *testing.T) {
	gfx := &mockGraphics{}
	eng, cancel := testEngine(t, gfx)
	defer cancel()

	data := []byte("same-image-data")
	sendUpload(t, eng, "client1", data)
	sendUpload(t, eng, "client1", data) // same data

	time.Sleep(50 * time.Millisecond)
	gfx.mu.Lock()
	defer gfx.mu.Unlock()
	if len(gfx.transmits) != 1 {
		t.Fatalf("expected 1 transmit (cache hit), got %d", len(gfx.transmits))
	}
}

func TestPlaceTriggersGraphicsPlace(t *testing.T) {
	gfx := &mockGraphics{}
	eng, cancel := testEngine(t, gfx)
	defer cancel()

	handle := sendUpload(t, eng, "client1", []byte("img"))

	reply := make(chan PlaceReply, 1)
	eng.Events <- PlaceRequest{
		ClientID: "client1",
		Params: protocol.PlaceParams{
			Handle: handle,
			Anchor: protocol.Anchor{Type: "absolute", Row: 5, Col: 10},
			Width:  20,
			Height: 15,
		},
		Reply: reply,
	}

	select {
	case r := <-reply:
		if r.Err != nil {
			t.Fatalf("place error: %v", r.Err)
		}
		if r.PlacementID == 0 {
			t.Fatal("expected non-zero placement ID")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("place timed out")
	}

	time.Sleep(50 * time.Millisecond)
	gfx.mu.Lock()
	defer gfx.mu.Unlock()
	if len(gfx.places) != 1 {
		t.Fatalf("expected 1 place call, got %d", len(gfx.places))
	}
	if gfx.places[0].Row != 5 || gfx.places[0].Col != 10 {
		t.Errorf("expected row=5 col=10, got row=%d col=%d", gfx.places[0].Row, gfx.places[0].Col)
	}
}

func TestUnplaceTriggersDelete(t *testing.T) {
	gfx := &mockGraphics{}
	eng, cancel := testEngine(t, gfx)
	defer cancel()

	handle := sendUpload(t, eng, "client1", []byte("img"))

	reply := make(chan PlaceReply, 1)
	eng.Events <- PlaceRequest{
		ClientID: "client1",
		Params: protocol.PlaceParams{
			Handle: handle,
			Anchor: protocol.Anchor{Type: "absolute", Row: 1, Col: 1},
			Width:  5,
			Height: 5,
		},
		Reply: reply,
	}
	r := <-reply
	if r.Err != nil {
		t.Fatalf("place error: %v", r.Err)
	}

	eng.Events <- UnplaceRequest{
		ClientID: "client1",
		Params:   protocol.UnplaceParams{PlacementID: r.PlacementID},
	}

	time.Sleep(100 * time.Millisecond)
	gfx.mu.Lock()
	defer gfx.mu.Unlock()
	if len(gfx.deletes) != 1 {
		t.Fatalf("expected 1 delete call, got %d", len(gfx.deletes))
	}
}

func TestClientDisconnectCleansUp(t *testing.T) {
	gfx := &mockGraphics{}
	eng, cancel := testEngine(t, gfx)
	defer cancel()

	handle := sendUpload(t, eng, "client1", []byte("img"))

	reply := make(chan PlaceReply, 1)
	eng.Events <- PlaceRequest{
		ClientID: "client1",
		Params: protocol.PlaceParams{
			Handle: handle,
			Anchor: protocol.Anchor{Type: "absolute", Row: 1, Col: 1},
			Width:  5,
			Height: 5,
		},
		Reply: reply,
	}
	<-reply

	eng.ClientDisconnected("client1")

	time.Sleep(100 * time.Millisecond)
	gfx.mu.Lock()
	defer gfx.mu.Unlock()
	// Should have delete for the placement
	if len(gfx.deletes) != 1 {
		t.Fatalf("expected 1 delete on disconnect, got %d", len(gfx.deletes))
	}
}

func sendPlace(t *testing.T, eng *Engine, clientID string, handle uint32, anchor protocol.Anchor, w, h int) uint32 {
	t.Helper()
	reply := make(chan PlaceReply, 1)
	eng.Events <- PlaceRequest{
		ClientID: clientID,
		Params: protocol.PlaceParams{
			Handle: handle,
			Anchor: anchor,
			Width:  w,
			Height: h,
		},
		Reply: reply,
	}
	select {
	case r := <-reply:
		if r.Err != nil {
			t.Fatalf("place error: %v", r.Err)
		}
		return r.PlacementID
	case <-time.After(2 * time.Second):
		t.Fatal("place timed out")
		return 0
	}
}

func TestPaneAnchorPlacement(t *testing.T) {
	gfx := &mockGraphics{}
	eng, cancel := testEngine(t, gfx)
	defer cancel()

	// Set up pane geometry
	eng.Events <- UpdatePanes{Panes: []PaneGeometry{
		{ID: "%0", Top: 5, Left: 10, Width: 80, Height: 24, Active: true},
	}}
	time.Sleep(50 * time.Millisecond)

	handle := sendUpload(t, eng, "client1", []byte("pane-img"))
	sendPlace(t, eng, "client1", handle, protocol.Anchor{
		Type:   "pane",
		PaneID: "%0",
		Row:    2,
		Col:    3,
	}, 10, 5)

	time.Sleep(50 * time.Millisecond)
	gfx.mu.Lock()
	defer gfx.mu.Unlock()
	if len(gfx.places) != 1 {
		t.Fatalf("expected 1 place, got %d", len(gfx.places))
	}
	// row=5+2=7, col=10+3=13
	if gfx.places[0].Row != 7 || gfx.places[0].Col != 13 {
		t.Errorf("expected row=7 col=13, got row=%d col=%d", gfx.places[0].Row, gfx.places[0].Col)
	}
}

func TestPaneAnchorUnknownPaneNotVisible(t *testing.T) {
	gfx := &mockGraphics{}
	eng, cancel := testEngine(t, gfx)
	defer cancel()

	handle := sendUpload(t, eng, "client1", []byte("no-pane-img"))
	sendPlace(t, eng, "client1", handle, protocol.Anchor{
		Type:   "pane",
		PaneID: "%99", // doesn't exist
		Row:    0,
		Col:    0,
	}, 5, 5)

	time.Sleep(50 * time.Millisecond)
	gfx.mu.Lock()
	defer gfx.mu.Unlock()
	// Should not be placed (pane not found)
	if len(gfx.places) != 0 {
		t.Fatalf("expected 0 places for unknown pane, got %d", len(gfx.places))
	}
}

func TestInactivePaneSuppressesPlacement(t *testing.T) {
	gfx := &mockGraphics{}
	eng, cancel := testEngine(t, gfx)
	defer cancel()

	// Set up an inactive pane
	eng.Events <- UpdatePanes{Panes: []PaneGeometry{
		{ID: "%0", Top: 0, Left: 0, Width: 80, Height: 24, Active: false},
	}}
	time.Sleep(50 * time.Millisecond)

	handle := sendUpload(t, eng, "client1", []byte("inactive-img"))
	sendPlace(t, eng, "client1", handle, protocol.Anchor{
		Type:   "pane",
		PaneID: "%0",
		Row:    0,
		Col:    0,
	}, 5, 5)

	time.Sleep(50 * time.Millisecond)
	gfx.mu.Lock()
	defer gfx.mu.Unlock()
	// Should not be placed (pane inactive)
	if len(gfx.places) != 0 {
		t.Fatalf("expected 0 places for inactive pane, got %d", len(gfx.places))
	}
}

func TestTopologyUpdateTriggersRecompute(t *testing.T) {
	gfx := &mockGraphics{}
	eng, cancel := testEngine(t, gfx)
	defer cancel()

	// Place in pane %0 (initially unknown → not visible)
	handle := sendUpload(t, eng, "client1", []byte("topo-img"))
	sendPlace(t, eng, "client1", handle, protocol.Anchor{
		Type:   "pane",
		PaneID: "%0",
		Row:    0,
		Col:    0,
	}, 5, 5)

	time.Sleep(50 * time.Millisecond)
	gfx.mu.Lock()
	if len(gfx.places) != 0 {
		t.Fatalf("expected 0 places before pane appears, got %d", len(gfx.places))
	}
	gfx.mu.Unlock()

	// Now the pane appears via topology update
	eng.Events <- UpdatePanes{Panes: []PaneGeometry{
		{ID: "%0", Top: 0, Left: 0, Width: 80, Height: 24, Active: true},
	}}

	time.Sleep(100 * time.Millisecond)
	gfx.mu.Lock()
	defer gfx.mu.Unlock()
	// Should now be placed
	if len(gfx.places) != 1 {
		t.Fatalf("expected 1 place after topology update, got %d", len(gfx.places))
	}
}

func TestWindowSwitchHidesAndShowsPlacements(t *testing.T) {
	gfx := &mockGraphics{}
	eng, cancel := testEngine(t, gfx)
	defer cancel()

	// Start with pane active
	eng.Events <- UpdatePanes{Panes: []PaneGeometry{
		{ID: "%0", Top: 0, Left: 0, Width: 80, Height: 24, Active: true},
	}}
	time.Sleep(50 * time.Millisecond)

	handle := sendUpload(t, eng, "client1", []byte("switch-img"))
	sendPlace(t, eng, "client1", handle, protocol.Anchor{
		Type:   "pane",
		PaneID: "%0",
		Row:    0,
		Col:    0,
	}, 5, 5)

	time.Sleep(50 * time.Millisecond)
	gfx.mu.Lock()
	if len(gfx.places) != 1 {
		t.Fatalf("expected 1 place, got %d", len(gfx.places))
	}
	gfx.mu.Unlock()

	// Switch window — pane becomes inactive
	eng.Events <- UpdatePanes{Panes: []PaneGeometry{
		{ID: "%0", Top: 0, Left: 0, Width: 80, Height: 24, Active: false},
	}}

	time.Sleep(100 * time.Millisecond)
	gfx.mu.Lock()
	// Should have deleted the placement
	if len(gfx.deletes) != 1 {
		t.Fatalf("expected 1 delete on window switch, got %d", len(gfx.deletes))
	}
	gfx.mu.Unlock()

	// Switch back — pane becomes active again
	eng.Events <- UpdatePanes{Panes: []PaneGeometry{
		{ID: "%0", Top: 0, Left: 0, Width: 80, Height: 24, Active: true},
	}}

	time.Sleep(100 * time.Millisecond)
	gfx.mu.Lock()
	defer gfx.mu.Unlock()
	// Should have re-placed
	if len(gfx.places) != 2 {
		t.Fatalf("expected 2 places (initial + re-place), got %d", len(gfx.places))
	}
}

func TestNvimWinPlacement(t *testing.T) {
	gfx := &mockGraphics{}
	eng, cancel := testEngine(t, gfx)
	defer cancel()

	// Register a neovim window at row 2, col 5 with height 20
	eng.Events <- RegisterWin{
		ClientID: "nvim1",
		Params: protocol.RegisterWinParams{
			WinID:     1000,
			Top:       2,
			Left:      5,
			Width:     40,
			Height:    20,
			ScrollTop: 0,
		},
	}
	time.Sleep(50 * time.Millisecond)

	handle := sendUpload(t, eng, "nvim1", []byte("nvim-img"))
	pid := sendPlace(t, eng, "nvim1", handle, protocol.Anchor{
		Type:    "nvim_win",
		WinID:   1000,
		BufLine: 3,
		Col:     1,
	}, 10, 5)

	if pid == 0 {
		t.Fatal("expected non-zero placement ID")
	}

	time.Sleep(50 * time.Millisecond)
	gfx.mu.Lock()
	defer gfx.mu.Unlock()
	if len(gfx.places) != 1 {
		t.Fatalf("expected 1 place, got %d", len(gfx.places))
	}
	// screenRow = win.Top + (bufLine - scrollTop) = 2 + (3 - 0) = 5
	// col = win.Left + anchor.Col = 5 + 1 = 6
	if gfx.places[0].Row != 5 || gfx.places[0].Col != 6 {
		t.Errorf("expected row=5 col=6, got row=%d col=%d", gfx.places[0].Row, gfx.places[0].Col)
	}
}

func TestNvimWinScrollHidesPlacement(t *testing.T) {
	gfx := &mockGraphics{}
	eng, cancel := testEngine(t, gfx)
	defer cancel()

	// Register window with height 10
	eng.Events <- RegisterWin{
		ClientID: "nvim1",
		Params: protocol.RegisterWinParams{
			WinID:     1000,
			Top:       0,
			Left:      0,
			Width:     80,
			Height:    10,
			ScrollTop: 0,
		},
	}
	time.Sleep(50 * time.Millisecond)

	handle := sendUpload(t, eng, "nvim1", []byte("scroll-img"))
	sendPlace(t, eng, "nvim1", handle, protocol.Anchor{
		Type:    "nvim_win",
		WinID:   1000,
		BufLine: 5, // visible at scroll=0 (screenRow=5, within height=10)
		Col:     0,
	}, 5, 5)

	time.Sleep(50 * time.Millisecond)
	gfx.mu.Lock()
	if len(gfx.places) != 1 {
		t.Fatalf("expected 1 place initially, got %d", len(gfx.places))
	}
	gfx.mu.Unlock()

	// Scroll down so bufLine 5 goes off screen (screenRow = 0 + (5-6) = -1)
	eng.Events <- ScrollUpdate{
		ClientID: "nvim1",
		Params:   protocol.UpdateScrollParams{WinID: 1000, ScrollTop: 6},
	}

	time.Sleep(100 * time.Millisecond)
	gfx.mu.Lock()
	defer gfx.mu.Unlock()
	if len(gfx.deletes) != 1 {
		t.Fatalf("expected 1 delete after scroll, got %d", len(gfx.deletes))
	}
}

func TestNvimWinScrollShowsPlacement(t *testing.T) {
	gfx := &mockGraphics{}
	eng, cancel := testEngine(t, gfx)
	defer cancel()

	// Register window with height 10, scrolled past line 20
	eng.Events <- RegisterWin{
		ClientID: "nvim1",
		Params: protocol.RegisterWinParams{
			WinID:     1000,
			Top:       0,
			Left:      0,
			Width:     80,
			Height:    10,
			ScrollTop: 25,
		},
	}
	time.Sleep(50 * time.Millisecond)

	handle := sendUpload(t, eng, "nvim1", []byte("scroll-show-img"))
	sendPlace(t, eng, "nvim1", handle, protocol.Anchor{
		Type:    "nvim_win",
		WinID:   1000,
		BufLine: 5, // off screen (screenRow = 0 + (5-25) = -20)
		Col:     0,
	}, 5, 5)

	time.Sleep(50 * time.Millisecond)
	gfx.mu.Lock()
	if len(gfx.places) != 0 {
		t.Fatalf("expected 0 places while off-screen, got %d", len(gfx.places))
	}
	gfx.mu.Unlock()

	// Scroll back to make line 5 visible (screenRow = 0 + (5-3) = 2, within height=10)
	eng.Events <- ScrollUpdate{
		ClientID: "nvim1",
		Params:   protocol.UpdateScrollParams{WinID: 1000, ScrollTop: 3},
	}

	time.Sleep(100 * time.Millisecond)
	gfx.mu.Lock()
	defer gfx.mu.Unlock()
	if len(gfx.places) != 1 {
		t.Fatalf("expected 1 place after scrolling into view, got %d", len(gfx.places))
	}
	if gfx.places[0].Row != 2 {
		t.Errorf("expected row=2, got row=%d", gfx.places[0].Row)
	}
}

func TestNvimWinUnregisterHidesPlacement(t *testing.T) {
	gfx := &mockGraphics{}
	eng, cancel := testEngine(t, gfx)
	defer cancel()

	eng.Events <- RegisterWin{
		ClientID: "nvim1",
		Params: protocol.RegisterWinParams{
			WinID:  1000,
			Top:    0,
			Left:   0,
			Width:  80,
			Height: 24,
		},
	}
	time.Sleep(50 * time.Millisecond)

	handle := sendUpload(t, eng, "nvim1", []byte("unreg-img"))
	sendPlace(t, eng, "nvim1", handle, protocol.Anchor{
		Type:    "nvim_win",
		WinID:   1000,
		BufLine: 0,
		Col:     0,
	}, 5, 5)

	time.Sleep(50 * time.Millisecond)
	gfx.mu.Lock()
	if len(gfx.places) != 1 {
		t.Fatalf("expected 1 place, got %d", len(gfx.places))
	}
	gfx.mu.Unlock()

	// Unregister the window
	eng.Events <- UnregisterWin{ClientID: "nvim1", WinID: 1000}

	time.Sleep(100 * time.Millisecond)
	gfx.mu.Lock()
	defer gfx.mu.Unlock()
	if len(gfx.deletes) != 1 {
		t.Fatalf("expected 1 delete after unregister, got %d", len(gfx.deletes))
	}
}

func TestNvimWinInsideTmuxPane(t *testing.T) {
	gfx := &mockGraphics{}
	eng, cancel := testEngine(t, gfx)
	defer cancel()

	// Set up tmux pane at offset (3, 5)
	eng.Events <- UpdatePanes{Panes: []PaneGeometry{
		{ID: "%0", Top: 3, Left: 5, Width: 80, Height: 24, Active: true},
	}}
	time.Sleep(50 * time.Millisecond)

	// Register nvim window inside the pane
	eng.Events <- RegisterWin{
		ClientID: "nvim1",
		Params: protocol.RegisterWinParams{
			WinID:     1000,
			PaneID:    "%0",
			Top:       1,
			Left:      2,
			Width:     40,
			Height:    10,
			ScrollTop: 0,
		},
	}
	time.Sleep(50 * time.Millisecond)

	handle := sendUpload(t, eng, "nvim1", []byte("tmux-nvim-img"))
	sendPlace(t, eng, "nvim1", handle, protocol.Anchor{
		Type:    "nvim_win",
		WinID:   1000,
		BufLine: 2,
		Col:     1,
	}, 5, 5)

	time.Sleep(50 * time.Millisecond)
	gfx.mu.Lock()
	defer gfx.mu.Unlock()
	if len(gfx.places) != 1 {
		t.Fatalf("expected 1 place, got %d", len(gfx.places))
	}
	// screenRow = win.Top + (bufLine - scrollTop) = 1 + 2 = 3
	// then add pane offset: row = 3 + 3 = 6
	// col = win.Left + anchor.Col = 2 + 1 = 3, then add pane: 3 + 5 = 8
	if gfx.places[0].Row != 6 || gfx.places[0].Col != 8 {
		t.Errorf("expected row=6 col=8, got row=%d col=%d", gfx.places[0].Row, gfx.places[0].Col)
	}
}

func TestNvimWinInInactivePaneNotVisible(t *testing.T) {
	gfx := &mockGraphics{}
	eng, cancel := testEngine(t, gfx)
	defer cancel()

	// Pane is inactive (different tmux window)
	eng.Events <- UpdatePanes{Panes: []PaneGeometry{
		{ID: "%0", Top: 0, Left: 0, Width: 80, Height: 24, Active: false},
	}}
	time.Sleep(50 * time.Millisecond)

	eng.Events <- RegisterWin{
		ClientID: "nvim1",
		Params: protocol.RegisterWinParams{
			WinID:  1000,
			PaneID: "%0",
			Top:    0,
			Left:   0,
			Width:  80,
			Height: 24,
		},
	}
	time.Sleep(50 * time.Millisecond)

	handle := sendUpload(t, eng, "nvim1", []byte("inactive-nvim-img"))
	sendPlace(t, eng, "nvim1", handle, protocol.Anchor{
		Type:    "nvim_win",
		WinID:   1000,
		BufLine: 0,
		Col:     0,
	}, 5, 5)

	time.Sleep(50 * time.Millisecond)
	gfx.mu.Lock()
	defer gfx.mu.Unlock()
	if len(gfx.places) != 0 {
		t.Fatalf("expected 0 places for nvim_win in inactive pane, got %d", len(gfx.places))
	}
}

func TestNvimWinNonZeroTop(t *testing.T) {
	gfx := &mockGraphics{}
	eng, cancel := testEngine(t, gfx)
	defer cancel()

	// Window starts at row 15 with height 5 (no pane)
	eng.Events <- RegisterWin{
		ClientID: "nvim1",
		Params: protocol.RegisterWinParams{
			WinID:     1000,
			Top:       15,
			Left:      0,
			Width:     80,
			Height:    5,
			ScrollTop: 0,
		},
	}
	time.Sleep(50 * time.Millisecond)

	handle := sendUpload(t, eng, "nvim1", []byte("nonzero-top-img"))
	sendPlace(t, eng, "nvim1", handle, protocol.Anchor{
		Type:    "nvim_win",
		WinID:   1000,
		BufLine: 2,
		Col:     0,
	}, 5, 5)

	time.Sleep(50 * time.Millisecond)
	gfx.mu.Lock()
	defer gfx.mu.Unlock()
	if len(gfx.places) != 1 {
		t.Fatalf("expected 1 place, got %d", len(gfx.places))
	}
	// row = win.Top + (bufLine - scrollTop) = 15 + 2 = 17
	if gfx.places[0].Row != 17 {
		t.Errorf("expected row=17, got row=%d", gfx.places[0].Row)
	}
}

func TestNvimWinRegisterAfterPlace(t *testing.T) {
	gfx := &mockGraphics{}
	eng, cancel := testEngine(t, gfx)
	defer cancel()

	// Place image into unregistered window first
	handle := sendUpload(t, eng, "nvim1", []byte("late-register-img"))
	sendPlace(t, eng, "nvim1", handle, protocol.Anchor{
		Type:    "nvim_win",
		WinID:   1000,
		BufLine: 0,
		Col:     0,
	}, 5, 5)

	time.Sleep(50 * time.Millisecond)
	gfx.mu.Lock()
	if len(gfx.places) != 0 {
		t.Fatalf("expected 0 places before window registration, got %d", len(gfx.places))
	}
	gfx.mu.Unlock()

	// Now register the window — placement should appear
	eng.Events <- RegisterWin{
		ClientID: "nvim1",
		Params: protocol.RegisterWinParams{
			WinID:  1000,
			Top:    0,
			Left:   0,
			Width:  80,
			Height: 24,
		},
	}

	time.Sleep(100 * time.Millisecond)
	gfx.mu.Lock()
	defer gfx.mu.Unlock()
	if len(gfx.places) != 1 {
		t.Fatalf("expected 1 place after late registration, got %d", len(gfx.places))
	}
}

func TestHelloReturnsTerminalInfo(t *testing.T) {
	gfx := &mockGraphics{}
	eng, cancel := testEngine(t, gfx)
	defer cancel()

	// Simulate terminal size
	eng.writer.Size <- tty.WinSize{Rows: 24, Cols: 80, XPixel: 640, YPixel: 384}
	time.Sleep(50 * time.Millisecond)

	reply := make(chan HelloReply, 1)
	eng.Events <- HelloRequest{
		ClientID: "client1",
		Params:   protocol.HelloParams{ClientType: "test", Label: "test"},
		Reply:    reply,
	}

	select {
	case r := <-reply:
		if r.Err != nil {
			t.Fatalf("hello error: %v", r.Err)
		}
		if r.Result.Rows != 24 || r.Result.Cols != 80 {
			t.Errorf("expected 24x80, got %dx%d", r.Result.Rows, r.Result.Cols)
		}
		if r.Result.CellWidth != 8 || r.Result.CellHeight != 16 {
			t.Errorf("expected cell 8x16, got %dx%d", r.Result.CellWidth, r.Result.CellHeight)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("hello timed out")
	}
}
