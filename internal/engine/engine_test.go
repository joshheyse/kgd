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
