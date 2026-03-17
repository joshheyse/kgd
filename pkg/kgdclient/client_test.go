package kgdclient

import (
	"context"
	"net"
	"path/filepath"
	"testing"

	"github.com/joshheyse/kgd/internal/allocator"
	"github.com/joshheyse/kgd/internal/engine"
	"github.com/joshheyse/kgd/internal/protocol"
	"github.com/joshheyse/kgd/internal/rpc"
	"github.com/joshheyse/kgd/internal/tty"
	"github.com/joshheyse/kgd/internal/upload"
)

func startTestServer(t *testing.T) (string, context.CancelFunc) {
	t.Helper()

	sock := filepath.Join(t.TempDir(), "test.sock")
	w := &tty.Writer{
		Writes: make(chan []byte, 64),
		Size:   make(chan tty.WinSize, 4),
		Colors: make(chan tty.TermColors, 2),
	}
	idAlloc := allocator.New()
	cache := upload.NewCache(256)
	eng := engine.New(w, nil, idAlloc, cache)
	srv := rpc.NewServer(sock, eng)

	ctx, cancel := context.WithCancel(context.Background())
	go eng.Run(ctx)
	go func() {
		_ = srv.Run(ctx)
	}()

	// Wait for socket to appear
	for range 50 {
		if conn, err := net.Dial("unix", sock); err == nil {
			conn.Close()
			break
		}
	}

	return sock, cancel
}

func TestClientConnect(t *testing.T) {
	sock, cancel := startTestServer(t)
	defer cancel()

	client, err := Connect(context.Background(), Options{
		SocketPath: sock,
		ClientType: "test",
		Label:      "test-client",
	})
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	defer client.Close()

	if client.ClientID == "" {
		t.Fatal("expected non-empty client ID")
	}
}

func TestClientUploadAndPlace(t *testing.T) {
	sock, cancel := startTestServer(t)
	defer cancel()

	client, err := Connect(context.Background(), Options{
		SocketPath: sock,
		ClientType: "test",
	})
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	defer client.Close()

	// Upload
	handle, err := client.Upload(context.Background(), []byte("test-png-data"), "png", 100, 100)
	if err != nil {
		t.Fatalf("upload: %v", err)
	}
	if handle == 0 {
		t.Fatal("expected non-zero handle")
	}

	// Place
	pid, err := client.Place(context.Background(), handle, protocol.Anchor{
		Type: "absolute",
		Row:  5,
		Col:  10,
	}, 20, 15, nil)
	if err != nil {
		t.Fatalf("place: %v", err)
	}
	if pid == 0 {
		t.Fatal("expected non-zero placement ID")
	}

	// List
	lr, err := client.List(context.Background())
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if len(lr.Placements) != 1 {
		t.Fatalf("expected 1 placement, got %d", len(lr.Placements))
	}

	// Unplace
	if err := client.Unplace(pid); err != nil {
		t.Fatalf("unplace: %v", err)
	}

	// Free
	if err := client.Free(handle); err != nil {
		t.Fatalf("free: %v", err)
	}
}

func TestClientStatus(t *testing.T) {
	sock, cancel := startTestServer(t)
	defer cancel()

	client, err := Connect(context.Background(), Options{
		SocketPath: sock,
		ClientType: "test",
	})
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	defer client.Close()

	// Upload something so we register as a client with images
	_, err = client.Upload(context.Background(), []byte("data"), "png", 10, 10)
	if err != nil {
		t.Fatalf("upload: %v", err)
	}

	status, err := client.Status(context.Background())
	if err != nil {
		t.Fatalf("status: %v", err)
	}
	if status.Clients < 1 {
		t.Fatalf("expected at least 1 client, got %d", status.Clients)
	}
}
