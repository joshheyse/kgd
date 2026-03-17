package daemon

import (
	"context"
	"fmt"
	"log/slog"
	"net"
	"os"
	"sync"

	"github.com/joshheyse/kgd/internal/allocator"
	"github.com/joshheyse/kgd/internal/engine"
	"github.com/joshheyse/kgd/internal/graphics"
	"github.com/joshheyse/kgd/internal/rpc"
	"github.com/joshheyse/kgd/internal/topology"
	"github.com/joshheyse/kgd/internal/tty"
	"github.com/joshheyse/kgd/internal/upload"
	"github.com/joshheyse/kgd/pkg/kgdsocket"
)

// Config holds daemon configuration.
type Config struct {
	SocketPath string
}

// Daemon is the top-level kgd daemon, wiring together all subsystems.
type Daemon struct {
	cfg    Config
	writer *tty.Writer
	engine *engine.Engine
	server *rpc.Server
}

// New creates a new Daemon with the given config.
func New(cfg Config) (*Daemon, error) {
	if cfg.SocketPath == "" {
		cfg.SocketPath = kgdsocket.DefaultPath()
	}

	// Check for stale socket / already running daemon
	if err := checkSocket(cfg.SocketPath); err != nil {
		return nil, err
	}

	w, err := tty.NewWriter()
	if err != nil {
		return nil, fmt.Errorf("opening tty: %w", err)
	}

	gfx := graphics.NewTTYGraphics(w)
	idAlloc := allocator.New()
	cache := upload.NewCache(256)
	eng := engine.New(w, gfx, idAlloc, cache)
	srv := rpc.NewServer(cfg.SocketPath, eng)
	eng.SetNotifier(srv)

	return &Daemon{
		cfg:    cfg,
		writer: w,
		engine: eng,
		server: srv,
	}, nil
}

// Run starts all daemon goroutines and blocks until ctx is cancelled.
// Shutdown order: RPC server stops → engine cleans up → TTY writer drains and stops.
func (d *Daemon) Run(ctx context.Context) error {
	slog.Info("kgd daemon started", "socket", d.cfg.SocketPath, "pid", os.Getpid())

	// Allow engine to trigger graceful shutdown via stop command
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	d.engine.SetStopFunc(cancel)

	// TTY writer gets its own context — it must stay alive until the engine
	// finishes cleanup (sending delete commands to the Writes channel).
	writerCtx, writerCancel := context.WithCancel(context.Background())
	defer writerCancel()

	var writerWg sync.WaitGroup
	writerWg.Add(1)
	go func() {
		defer writerWg.Done()
		d.writer.Run(writerCtx)
	}()

	// Start the placement engine goroutine
	var engineWg sync.WaitGroup
	engineWg.Add(1)
	go func() {
		defer engineWg.Done()
		d.engine.Run(ctx)
	}()

	// Start tmux watcher if in tmux
	if d.writer.InTmux() {
		tmuxW := topology.NewTmuxWatcher(d.engine)
		engineWg.Add(1)
		go func() {
			defer engineWg.Done()
			tmuxW.Run(ctx)
		}()
	}

	// RPC server blocks until ctx is cancelled
	if err := d.server.Run(ctx); err != nil {
		return fmt.Errorf("rpc server: %w", err)
	}

	// Wait for engine to finish (includes cleanup: deleting placements, freeing images)
	engineWg.Wait()

	// Now stop the TTY writer — it has drained all cleanup commands.
	// writerCancel is deferred above, but call explicitly for clear shutdown ordering.
	writerCancel()
	writerWg.Wait()

	slog.Info("kgd daemon stopped")
	return nil
}

// checkSocket checks if a daemon is already running on the given socket path.
// If the socket exists but is stale (no listener), it is removed.
func checkSocket(path string) error {
	if _, err := os.Stat(path); os.IsNotExist(err) {
		return nil
	}

	// Try to connect — if it succeeds, another daemon is running
	conn, err := net.Dial("unix", path)
	if err == nil {
		conn.Close()
		return fmt.Errorf("kgd already running on %s", path)
	}

	// Connection failed — socket is stale, remove it
	slog.Info("removing stale socket", "path", path)
	return os.Remove(path)
}

// SocketPath returns the socket path for this daemon.
func (d *Daemon) SocketPath() string {
	return d.cfg.SocketPath
}

// DefaultSocketPath returns the default socket path for the current session.
func DefaultSocketPath() string {
	return kgdsocket.DefaultPath()
}
