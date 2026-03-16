package topology

import (
	"bufio"
	"context"
	"fmt"
	"log/slog"
	"os/exec"
	"strconv"
	"strings"
	"time"

	"github.com/joshheyse/kgd/internal/engine"
)

const (
	// debounceInterval prevents excessive pane queries on rapid layout changes.
	debounceInterval = 50 * time.Millisecond
	// queryTimeout prevents hanging on unresponsive tmux.
	queryTimeout = 5 * time.Second
)

// TmuxWatcher monitors tmux for pane layout changes and sends pane geometry
// updates to the placement engine. It uses tmux control mode (`tmux -C`) for
// real-time notifications with a polling fallback.
type TmuxWatcher struct {
	engine *engine.Engine
}

// NewTmuxWatcher creates a new TmuxWatcher.
func NewTmuxWatcher(eng *engine.Engine) *TmuxWatcher {
	return &TmuxWatcher{engine: eng}
}

// Run starts the tmux watcher. It connects via control mode for real-time
// layout change events, falling back to polling if control mode fails.
func (w *TmuxWatcher) Run(ctx context.Context) {
	slog.Info("tmux watcher started")
	defer slog.Info("tmux watcher stopped")

	// Send initial pane layout
	w.queryAndUpdate(ctx)

	// Try control mode first
	if err := w.runControlMode(ctx); err != nil {
		// Don't fall back to polling if we're shutting down
		if ctx.Err() != nil {
			return
		}
		slog.Warn("tmux control mode failed, falling back to polling", "error", err)
		w.runPolling(ctx)
	}
}

// runControlMode connects via `tmux -C attach` and watches for layout events.
// Note: this creates an additional tmux client attachment visible in `tmux list-clients`.
func (w *TmuxWatcher) runControlMode(ctx context.Context) error {
	cmd := exec.CommandContext(ctx, "tmux", "-C", "attach")
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return fmt.Errorf("stdout pipe: %w", err)
	}

	if err := cmd.Start(); err != nil {
		return fmt.Errorf("starting tmux -C: %w", err)
	}

	scanner := bufio.NewScanner(stdout)
	var debounce *time.Timer

	for scanner.Scan() {
		line := scanner.Text()
		if shouldRefreshPanes(line) {
			// Debounce rapid events
			if debounce != nil {
				debounce.Stop()
			}
			debounce = time.AfterFunc(debounceInterval, func() {
				w.queryAndUpdate(ctx)
			})
		}
	}

	if debounce != nil {
		debounce.Stop()
	}
	cmd.Wait()

	// Don't report error if shutdown was intentional
	if ctx.Err() != nil {
		return nil
	}
	return fmt.Errorf("control mode exited")
}

// shouldRefreshPanes returns true if the control mode line indicates a layout change.
func shouldRefreshPanes(line string) bool {
	switch {
	case strings.HasPrefix(line, "%layout-change"):
		return true
	case strings.HasPrefix(line, "%window-pane-changed"):
		return true
	case strings.HasPrefix(line, "%session-window-changed"):
		return true
	case strings.HasPrefix(line, "%window-add"):
		return true
	case strings.HasPrefix(line, "%window-close"):
		return true
	case strings.HasPrefix(line, "%unlinked-window-add"):
		return true
	case strings.HasPrefix(line, "%unlinked-window-close"):
		return true
	default:
		return false
	}
}

// runPolling falls back to periodic pane queries.
func (w *TmuxWatcher) runPolling(ctx context.Context) {
	ticker := time.NewTicker(1 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			w.queryAndUpdate(ctx)
		}
	}
}

// queryAndUpdate queries tmux for pane geometries and sends them to the engine.
// Uses non-blocking send to avoid goroutine leaks during shutdown.
func (w *TmuxWatcher) queryAndUpdate(ctx context.Context) {
	panes, err := QueryPanes(ctx)
	if err != nil {
		if ctx.Err() != nil {
			return
		}
		slog.Debug("failed to query tmux panes", "error", err)
		return
	}
	select {
	case w.engine.Events <- engine.UpdatePanes{Panes: panes}:
	case <-ctx.Done():
	}
}

// QueryPanes queries tmux for all pane geometries in the current session.
// Uses -s to list panes across all windows in the session (not all sessions).
func QueryPanes(ctx context.Context) ([]engine.PaneGeometry, error) {
	queryCtx, cancel := context.WithTimeout(ctx, queryTimeout)
	defer cancel()

	out, err := exec.CommandContext(queryCtx, "tmux", "list-panes", "-s", "-F",
		"#{pane_id} #{pane_top} #{pane_left} #{pane_width} #{pane_height} #{window_active}").Output()
	if err != nil {
		return nil, fmt.Errorf("tmux list-panes: %w", err)
	}

	var panes []engine.PaneGeometry
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		if line == "" {
			continue
		}
		p, err := parsePaneLine(line)
		if err != nil {
			continue
		}
		panes = append(panes, p)
	}
	return panes, nil
}

// parsePaneLine parses a tmux list-panes output line.
// Format: "%0 0 0 80 24 1" (pane_id top left width height window_active)
func parsePaneLine(line string) (engine.PaneGeometry, error) {
	fields := strings.Fields(line)
	if len(fields) < 5 {
		return engine.PaneGeometry{}, fmt.Errorf("expected at least 5 fields, got %d", len(fields))
	}

	top, err := strconv.Atoi(fields[1])
	if err != nil {
		return engine.PaneGeometry{}, fmt.Errorf("parsing top: %w", err)
	}
	left, err := strconv.Atoi(fields[2])
	if err != nil {
		return engine.PaneGeometry{}, fmt.Errorf("parsing left: %w", err)
	}
	width, err := strconv.Atoi(fields[3])
	if err != nil {
		return engine.PaneGeometry{}, fmt.Errorf("parsing width: %w", err)
	}
	height, err := strconv.Atoi(fields[4])
	if err != nil {
		return engine.PaneGeometry{}, fmt.Errorf("parsing height: %w", err)
	}

	active := true
	if len(fields) >= 6 {
		active = fields[5] == "1"
	}

	return engine.PaneGeometry{
		ID:     fields[0],
		Top:    top,
		Left:   left,
		Width:  width,
		Height: height,
		Active: active,
	}, nil
}
