package topology

import (
	"fmt"
	"os/exec"
	"strconv"
	"strings"

	"github.com/joshheyse/kgd/internal/engine"
)

// TmuxWatcher polls tmux for pane layout changes and sends TopologyEvents
// to the placement engine.
type TmuxWatcher struct {
	engine *engine.Engine
}

// NewTmuxWatcher creates a new TmuxWatcher.
func NewTmuxWatcher(eng *engine.Engine) *TmuxWatcher {
	return &TmuxWatcher{engine: eng}
}

// QueryPanes queries tmux for all pane geometries in the current window.
func (w *TmuxWatcher) QueryPanes() ([]engine.PaneGeometry, error) {
	// tmux display-message -p '#{pane_id} #{pane_top} #{pane_left} #{pane_width} #{pane_height}'
	// applied to all panes via list-panes
	out, err := exec.Command("tmux", "list-panes", "-F",
		"#{pane_id} #{pane_top} #{pane_left} #{pane_width} #{pane_height}").Output()
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

func parsePaneLine(line string) (engine.PaneGeometry, error) {
	fields := strings.Fields(line)
	if len(fields) != 5 {
		return engine.PaneGeometry{}, fmt.Errorf("expected 5 fields, got %d", len(fields))
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

	return engine.PaneGeometry{
		ID:     fields[0],
		Top:    top,
		Left:   left,
		Width:  width,
		Height: height,
	}, nil
}
