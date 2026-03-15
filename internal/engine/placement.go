package engine

import "github.com/joshheyse/kgd/internal/protocol"

// Placement represents a placed image on the terminal.
type Placement struct {
	ID          uint32
	ClientID    string
	ImageHandle uint32
	KittyImgID  uint32
	Anchor      protocol.Anchor
	Width       int
	Height      int
	SrcX        int
	SrcY        int
	SrcW        int
	SrcH        int
	ZIndex      int32

	// Resolved terminal coordinates (recomputed on topology changes)
	TermRow int
	TermCol int

	// Whether this placement is currently visible on screen
	Visible bool

	// Whether the placement has been rendered to the TTY
	Rendered bool
}

// ScreenPos computes the absolute terminal position for this placement
// given pane and window geometry. Returns (row, col, visible).
func (p *Placement) ScreenPos(panes map[string]PaneGeometry, wins map[int]WinGeometry) (int, int, bool) {
	switch p.Anchor.Type {
	case "absolute":
		return p.Anchor.Row, p.Anchor.Col, true

	case "pane":
		pane, ok := panes[p.Anchor.PaneID]
		if !ok {
			return 0, 0, false
		}
		row := pane.Top + p.Anchor.Row
		col := pane.Left + p.Anchor.Col
		visible := p.Anchor.Row >= 0 && p.Anchor.Row < pane.Height &&
			p.Anchor.Col >= 0 && p.Anchor.Col < pane.Width
		return row, col, visible

	case "nvim_win":
		win, ok := wins[p.Anchor.WinID]
		if !ok {
			return 0, 0, false
		}
		screenRow := win.Top + (p.Anchor.BufLine - win.ScrollTop)
		if screenRow < 0 || screenRow >= win.Height {
			return 0, 0, false
		}
		row := screenRow
		col := win.Left + p.Anchor.Col
		// If inside a tmux pane, add pane offset
		if win.PaneID != "" {
			if pane, ok := panes[win.PaneID]; ok {
				row += pane.Top
				col += pane.Left
			}
		}
		return row, col, true

	default:
		return 0, 0, false
	}
}

// PaneGeometry describes a tmux pane's position and size in terminal coordinates.
type PaneGeometry struct {
	ID     string
	Top    int
	Left   int
	Width  int
	Height int
}

// WinGeometry describes a neovim window's position within a pane.
type WinGeometry struct {
	WinID     int
	PaneID    string
	Top       int
	Left      int
	Width     int
	Height    int
	ScrollTop int
}
