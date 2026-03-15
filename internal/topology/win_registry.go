package topology

import "github.com/joshheyse/kgd/internal/engine"

// WinRegistry tracks registered neovim window geometries.
// Window state is managed through the engine's event loop;
// this file provides helper types and utilities.

// WinFromParams converts RegisterWinParams to WinGeometry.
func WinFromParams(clientID string, winID int, paneID string, top, left, width, height, scrollTop int) engine.WinGeometry {
	return engine.WinGeometry{
		WinID:     winID,
		PaneID:    paneID,
		Top:       top,
		Left:      left,
		Width:     width,
		Height:    height,
		ScrollTop: scrollTop,
	}
}
