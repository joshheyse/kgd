package daemon

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"

	"github.com/joshheyse/kgd/internal/engine"
	"github.com/joshheyse/kgd/internal/rpc"
	"github.com/joshheyse/kgd/internal/tty"
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
		cfg.SocketPath = defaultSocketPath()
	}

	w := tty.NewWriter()
	eng := engine.New(w)
	srv := rpc.NewServer(cfg.SocketPath, eng)

	return &Daemon{
		cfg:    cfg,
		writer: w,
		engine: eng,
		server: srv,
	}, nil
}

// Run starts all daemon goroutines and blocks until ctx is cancelled.
func (d *Daemon) Run(ctx context.Context) error {
	slog.Info("kgd daemon started", "socket", d.cfg.SocketPath, "pid", os.Getpid())

	// Start the TTY writer goroutine
	go d.writer.Run(ctx)

	// Start the placement engine goroutine
	go d.engine.Run(ctx)

	// Start the RPC server (blocks until ctx is cancelled)
	if err := d.server.Run(ctx); err != nil {
		return fmt.Errorf("rpc server: %w", err)
	}

	slog.Info("kgd daemon stopped")
	return nil
}

func defaultSocketPath() string {
	runtimeDir := os.Getenv("XDG_RUNTIME_DIR")
	if runtimeDir == "" {
		runtimeDir = os.TempDir()
	}

	kittyWindowID := os.Getenv("KITTY_WINDOW_ID")
	if kittyWindowID == "" {
		kittyWindowID = "default"
	}

	return filepath.Join(runtimeDir, fmt.Sprintf("kgd-%s.sock", kittyWindowID))
}
