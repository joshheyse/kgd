package daemon

import (
	"context"
	"fmt"
	"log/slog"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"

	"github.com/joshheyse/kgd/internal/allocator"
	"github.com/joshheyse/kgd/internal/engine"
	"github.com/joshheyse/kgd/internal/graphics"
	"github.com/joshheyse/kgd/internal/rpc"
	"github.com/joshheyse/kgd/internal/topology"
	"github.com/joshheyse/kgd/internal/tty"
	"github.com/joshheyse/kgd/internal/upload"
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
// Shutdown order: RPC server stops first, then engine drains, then TTY writer closes.
func (d *Daemon) Run(ctx context.Context) error {
	slog.Info("kgd daemon started", "socket", d.cfg.SocketPath, "pid", os.Getpid())

	// Allow engine to trigger graceful shutdown via stop command
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	d.engine.SetStopFunc(cancel)

	var wg sync.WaitGroup

	// Start the TTY writer goroutine
	wg.Add(1)
	go func() {
		defer wg.Done()
		d.writer.Run(ctx)
	}()

	// Start the placement engine goroutine
	wg.Add(1)
	go func() {
		defer wg.Done()
		d.engine.Run(ctx)
	}()

	// Start tmux watcher if in tmux
	if d.writer.InTmux() {
		tmuxW := topology.NewTmuxWatcher(d.engine)
		wg.Add(1)
		go func() {
			defer wg.Done()
			tmuxW.Run(ctx)
		}()
	}

	// Start the RPC server (blocks until ctx is cancelled)
	if err := d.server.Run(ctx); err != nil {
		return fmt.Errorf("rpc server: %w", err)
	}

	// Wait for engine and writer to finish
	wg.Wait()

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

// sessionKey computes a unique key for this terminal session.
// Priority: $KITTY_WINDOW_ID → $WEZTERM_PANE → TTY device path
func sessionKey() string {
	if id := os.Getenv("KITTY_WINDOW_ID"); id != "" {
		return "kitty-" + id
	}
	if id := os.Getenv("WEZTERM_PANE"); id != "" {
		return "wezterm-" + id
	}
	// Fall back to TTY device path
	ttyPath := ttyDevicePath()
	if ttyPath != "" {
		// Sanitize for use in filename
		safe := strings.ReplaceAll(ttyPath, "/", "-")
		safe = strings.TrimPrefix(safe, "-dev-")
		return "tty-" + safe
	}
	return "default"
}

// ttyDevicePath returns the path to the controlling terminal, or empty string.
func ttyDevicePath() string {
	// Read /proc/self/fd/0 symlink (Linux) or use os.Stdin stat (macOS)
	if target, err := os.Readlink("/proc/self/fd/0"); err == nil {
		if strings.HasPrefix(target, "/dev/") {
			return target
		}
	}
	// Fallback: check if stdin is a terminal
	if fi, err := os.Stdin.Stat(); err == nil {
		if fi.Mode()&os.ModeCharDevice != 0 {
			return fi.Name()
		}
	}
	return ""
}

// SocketPath returns the socket path for this daemon.
func (d *Daemon) SocketPath() string {
	return d.cfg.SocketPath
}

// DefaultSocketPath returns the default socket path for the current session.
func DefaultSocketPath() string {
	return defaultSocketPath()
}

func defaultSocketPath() string {
	runtimeDir := os.Getenv("XDG_RUNTIME_DIR")
	if runtimeDir == "" {
		runtimeDir = os.TempDir()
	}

	return filepath.Join(runtimeDir, fmt.Sprintf("kgd-%s.sock", sessionKey()))
}
