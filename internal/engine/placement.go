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
// termRows and termCols are used for absolute anchor bounds checking (0 means unknown/skip).
func (p *Placement) ScreenPos(panes map[string]PaneGeometry, wins map[int]WinGeometry, termRows, termCols int) (int, int, bool) {
	switch p.Anchor.Type {
	case "absolute":
		visible := p.Anchor.Row >= 0 && p.Anchor.Col >= 0
		if termRows > 0 {
			visible = visible && p.Anchor.Row < termRows
		}
		if termCols > 0 {
			visible = visible && p.Anchor.Col < termCols
		}
		return p.Anchor.Row, p.Anchor.Col, visible

	case "pane":
		pane, ok := panes[p.Anchor.PaneID]
		if !ok {
			return 0, 0, false
		}
		// Suppress placements in non-active tmux windows
		if !pane.Active {
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
		relRow := p.Anchor.BufLine - win.ScrollTop
		if relRow < 0 || relRow >= win.Height {
			return 0, 0, false
		}
		row := win.Top + relRow
		col := win.Left + p.Anchor.Col
		// If inside a tmux pane, add pane offset and check visibility
		if win.PaneID != "" {
			pane, ok := panes[win.PaneID]
			if !ok {
				return 0, 0, false
			}
			if !pane.Active {
				return 0, 0, false
			}
			row += pane.Top
			col += pane.Left
			// Verify result is within pane bounds
			if row < pane.Top || row >= pane.Top+pane.Height ||
				col < pane.Left || col >= pane.Left+pane.Width {
				return 0, 0, false
			}
		}
		return row, col, true

	default:
		return 0, 0, false
	}
}

// PlacementInfo interface methods for graphics rendering.

func (p *Placement) GetWidth() int    { return p.Width }
func (p *Placement) GetHeight() int   { return p.Height }
func (p *Placement) GetSrcX() int     { return p.SrcX }
func (p *Placement) GetSrcY() int     { return p.SrcY }
func (p *Placement) GetSrcW() int     { return p.SrcW }
func (p *Placement) GetSrcH() int     { return p.SrcH }
func (p *Placement) GetZIndex() int32 { return p.ZIndex }

// PaneGeometry describes a tmux pane's position and size in terminal coordinates.
type PaneGeometry struct {
	ID     string
	Top    int
	Left   int
	Width  int
	Height int
	Active bool // whether the pane's window is the active tmux window
}

// WinGeometry describes a neovim window's position within a pane.
type WinGeometry struct {
	WinID     int
	ClientID  string
	PaneID    string
	Top       int
	Left      int
	Width     int
	Height    int
	ScrollTop int
}
