package rpc

import (
	"context"
	"net"
	"path/filepath"
	"testing"
	"time"

	"github.com/joshheyse/kgd/internal/allocator"
	"github.com/joshheyse/kgd/internal/engine"
	"github.com/joshheyse/kgd/internal/protocol"
	"github.com/joshheyse/kgd/internal/tty"
	"github.com/joshheyse/kgd/internal/upload"
	"github.com/vmihailenco/msgpack/v5"
)

// testEngine creates a minimal engine for testing (nil graphics — no TTY writes).
func testEngine(t *testing.T) *engine.Engine {
	t.Helper()
	w := &tty.Writer{
		Writes: make(chan []byte, 64),
		Size:   make(chan tty.WinSize, 4),
		Colors: make(chan tty.TermColors, 2),
	}
	idAlloc := allocator.New()
	cache := upload.NewCache(256)
	eng := engine.New(w, nil, idAlloc, cache)
	return eng
}

// testSocket creates a real Unix socket pair for tests (kernel-buffered, no net.Pipe deadlocks).
func testSocket(t *testing.T) (serverConn, clientConn net.Conn) {
	t.Helper()
	sock := filepath.Join(t.TempDir(), "test.sock")
	ln, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })

	accepted := make(chan net.Conn, 1)
	go func() {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		accepted <- conn
	}()

	clientConn, err = net.Dial("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { clientConn.Close() })

	serverConn = <-accepted
	t.Cleanup(func() { serverConn.Close() })
	return serverConn, clientConn
}

// toUint32 converts a msgpack-decoded integer to uint32 regardless of the concrete type.
func toUint32(t *testing.T, v any) uint32 {
	t.Helper()
	switch n := v.(type) {
	case uint64:
		return uint32(n)
	case uint32:
		return n
	case int64:
		return uint32(n)
	case int8:
		return uint32(n)
	case uint8:
		return uint32(n)
	default:
		t.Fatalf("expected integer type, got %T: %v", v, v)
		return 0
	}
}

func sendRequest(enc *msgpack.Encoder, dec *msgpack.Decoder, msgID uint32, method string, params any) (any, any, error) {
	if err := enc.EncodeArrayLen(4); err != nil {
		return nil, nil, err
	}
	if err := enc.EncodeInt(0); err != nil {
		return nil, nil, err
	}
	if err := enc.EncodeUint32(msgID); err != nil {
		return nil, nil, err
	}
	if err := enc.EncodeString(method); err != nil {
		return nil, nil, err
	}
	if err := enc.EncodeArrayLen(1); err != nil {
		return nil, nil, err
	}
	if err := enc.Encode(params); err != nil {
		return nil, nil, err
	}

	// Read response: [1, msgid, error, result]
	if _, err := dec.DecodeArrayLen(); err != nil {
		return nil, nil, err
	}
	if _, err := dec.DecodeInt(); err != nil {
		return nil, nil, err
	}
	if _, err := dec.DecodeUint32(); err != nil {
		return nil, nil, err
	}
	var rpcErr any
	if err := dec.Decode(&rpcErr); err != nil {
		return nil, nil, err
	}
	var result any
	if err := dec.Decode(&result); err != nil {
		return nil, nil, err
	}
	return result, rpcErr, nil
}

func TestHelloRoundTrip(t *testing.T) {
	eng := testEngine(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go eng.Run(ctx)

	serverConn, clientConn := testSocket(t)

	client := NewClient(serverConn, eng, nil)
	go func() {
		_ = client.Serve(ctx)
	}()

	enc := msgpack.NewEncoder(clientConn)
	dec := msgpack.NewDecoder(clientConn)

	result, rpcErr, err := sendRequest(enc, dec, 1, "hello", protocol.HelloParams{
		ClientType: "test",
		PID:        12345,
		Label:      "test-client",
	})
	if err != nil {
		t.Fatalf("request error: %v", err)
	}
	if rpcErr != nil {
		t.Fatalf("rpc error: %v", rpcErr)
	}
	resultMap := result.(map[string]any)
	if resultMap["client_id"] == nil || resultMap["client_id"].(string) == "" {
		t.Fatal("expected non-empty client ID")
	}
}

func TestUploadAndPlaceRoundTrip(t *testing.T) {
	eng := testEngine(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go eng.Run(ctx)

	serverConn, clientConn := testSocket(t)

	client := NewClient(serverConn, eng, nil)
	go func() {
		_ = client.Serve(ctx)
	}()

	enc := msgpack.NewEncoder(clientConn)
	dec := msgpack.NewDecoder(clientConn)

	// 1. Hello
	_, _, err := sendRequest(enc, dec, 1, "hello", protocol.HelloParams{ClientType: "test"})
	if err != nil {
		t.Fatalf("hello error: %v", err)
	}

	// 2. Upload
	result, rpcErr, err := sendRequest(enc, dec, 2, "upload", protocol.UploadParams{
		Data:   []byte("fake-png-data"),
		Format: "png",
		Width:  100,
		Height: 100,
	})
	if err != nil {
		t.Fatalf("upload request error: %v", err)
	}
	if rpcErr != nil {
		t.Fatalf("upload rpc error: %v", rpcErr)
	}
	resultMap := result.(map[string]any)
	handle := toUint32(t, resultMap["handle"])
	if handle == 0 {
		t.Fatal("expected non-zero handle")
	}

	// 3. Place
	result, rpcErr, err = sendRequest(enc, dec, 3, "place", protocol.PlaceParams{
		Handle: handle,
		Anchor: protocol.Anchor{Type: "absolute", Row: 5, Col: 10},
		Width:  10,
		Height: 10,
	})
	if err != nil {
		t.Fatalf("place request error: %v", err)
	}
	if rpcErr != nil {
		t.Fatalf("place rpc error: %v", rpcErr)
	}
	resultMap = result.(map[string]any)
	placementID := toUint32(t, resultMap["placement_id"])
	if placementID == 0 {
		t.Fatal("expected non-zero placement_id")
	}
}

func TestUnknownMethodError(t *testing.T) {
	eng := testEngine(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go eng.Run(ctx)

	serverConn, clientConn := testSocket(t)

	client := NewClient(serverConn, eng, nil)
	go func() {
		_ = client.Serve(ctx)
	}()

	enc := msgpack.NewEncoder(clientConn)
	dec := msgpack.NewDecoder(clientConn)

	_, rpcErr, err := sendRequest(enc, dec, 1, "nonexistent_method", nil)
	if err != nil {
		t.Fatalf("request error: %v", err)
	}
	if rpcErr == nil {
		t.Fatal("expected error for unknown method")
	}
}

func TestUploadCacheHit(t *testing.T) {
	eng := testEngine(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go eng.Run(ctx)

	serverConn, clientConn := testSocket(t)

	client := NewClient(serverConn, eng, nil)
	go func() {
		_ = client.Serve(ctx)
	}()

	enc := msgpack.NewEncoder(clientConn)
	dec := msgpack.NewDecoder(clientConn)

	testData := []byte("same-image-data")

	// Upload #1
	result1, _, _ := sendRequest(enc, dec, 1, "upload", protocol.UploadParams{Data: testData, Format: "png", Width: 10, Height: 10})
	handle1 := toUint32(t, result1.(map[string]any)["handle"])

	// Upload #2 with same data — cache hit
	result2, _, _ := sendRequest(enc, dec, 2, "upload", protocol.UploadParams{Data: testData, Format: "png", Width: 10, Height: 10})
	handle2 := toUint32(t, result2.(map[string]any)["handle"])

	if handle1 == 0 || handle2 == 0 {
		t.Fatalf("expected non-zero handles, got %d and %d", handle1, handle2)
	}
}

func TestSendNotification(t *testing.T) {
	eng := testEngine(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go eng.Run(ctx)

	serverConn, clientConn := testSocket(t)

	client := NewClient(serverConn, eng, nil)
	go func() {
		_ = client.Serve(ctx)
	}()

	err := client.SendNotification("theme_changed", protocol.ThemeChangedParams{
		FG: protocol.Color{R: 0xFFFF, G: 0xFFFF, B: 0xFFFF},
		BG: protocol.Color{R: 0, G: 0, B: 0},
	})
	if err != nil {
		t.Fatalf("sending notification: %v", err)
	}

	dec := msgpack.NewDecoder(clientConn)
	done := make(chan struct{})
	go func() {
		defer close(done)
		arrLen, err := dec.DecodeArrayLen()
		if err != nil {
			t.Errorf("decoding notification: %v", err)
			return
		}
		if arrLen != 3 {
			t.Errorf("expected 3-element array, got %d", arrLen)
			return
		}
		msgType, _ := dec.DecodeInt()
		if msgType != 2 {
			t.Errorf("expected notification type 2, got %d", msgType)
			return
		}
		method, _ := dec.DecodeString()
		if method != "theme_changed" {
			t.Errorf("expected theme_changed, got %s", method)
			return
		}
	}()

	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for notification")
	}
}
