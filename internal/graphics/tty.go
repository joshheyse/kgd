package graphics

import (
	"log/slog"

	"github.com/joshheyse/kgd/internal/kitty"
	"github.com/joshheyse/kgd/internal/tty"
)

// TTYGraphics implements Graphics by writing kitty protocol sequences to a TTY.
type TTYGraphics struct {
	writer   *tty.Writer
	inTmux   bool
	batching bool
	batch    []byte
}

// NewTTYGraphics creates a new TTYGraphics backed by the given TTY writer.
func NewTTYGraphics(writer *tty.Writer) *TTYGraphics {
	return &TTYGraphics{
		writer: writer,
		inTmux: writer.InTmux(),
	}
}

// Transmit sends image data to the terminal.
// Each chunk is sent as a separate write to avoid interleaving with other
// processes writing to the same PTY (shell prompt, tmux client output).
func (g *TTYGraphics) Transmit(id uint32, data []byte, format string, width, height int) error {
	slog.Info("gfx transmit", "id", id, "format", format, "dataLen", len(data), "tmux", g.inTmux)
	cmd := kitty.TransmitCommand{
		ImageID: id,
		Format:  format,
		Width:   width,
		Height:  height,
	}

	chunks := cmd.SerializeChunks(data)
	slog.Info("gfx transmit chunks", "count", len(chunks))

	for _, chunk := range chunks {
		if g.inTmux {
			chunk = kitty.WrapTmux(chunk)
		}
		// Send each chunk individually so each write() is small and atomic.
		// This prevents interleaving with shell output on the same PTY.
		g.writer.Writes <- []byte(chunk)
	}
	return nil
}

func (g *TTYGraphics) Place(imageID, placementID uint32, row, col int, p PlacementInfo) error {
	slog.Info("gfx place", "imageID", imageID, "placementID", placementID, "row", row, "col", col, "tmux", g.inTmux)
	cmd := kitty.PlaceCommand{
		ImageID:     imageID,
		PlacementID: placementID,
		Row:         row,
		Col:         col,
		Width:       p.GetWidth(),
		Height:      p.GetHeight(),
		SrcX:        p.GetSrcX(),
		SrcY:        p.GetSrcY(),
		SrcW:        p.GetSrcW(),
		SrcH:        p.GetSrcH(),
		ZIndex:      p.GetZIndex(),
	}
	g.send(cmd.Serialize())
	return nil
}

func (g *TTYGraphics) Delete(imageID, placementID uint32, free bool) error {
	cmd := kitty.DeleteCommand{
		ImageID:     imageID,
		PlacementID: placementID,
		Free:        free,
	}
	g.send(cmd.Serialize())
	return nil
}

// send writes a kitty escape sequence, wrapping for tmux DCS passthrough if needed
// and accumulating into the batch buffer if batching.
func (g *TTYGraphics) send(seq string) {
	if g.inTmux {
		seq = kitty.WrapTmux(seq)
	}
	if g.batching {
		g.batch = append(g.batch, seq...)
		return
	}
	g.writer.Writes <- []byte(seq)
}

func (g *TTYGraphics) BeginBatch() {
	g.batching = true
	g.batch = g.batch[:0]
}

func (g *TTYGraphics) FlushBatch() {
	if len(g.batch) > 0 {
		g.writer.Writes <- append([]byte(nil), g.batch...)
	}
	g.batch = g.batch[:0]
	g.batching = false
}
