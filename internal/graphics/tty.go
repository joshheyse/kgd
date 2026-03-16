package graphics

import (
	"strings"

	"github.com/joshheyse/kgd/internal/kitty"
	"github.com/joshheyse/kgd/internal/tty"
)

// TTYGraphics implements Graphics by writing kitty protocol sequences to a TTY.
type TTYGraphics struct {
	writer *tty.Writer
	inTmux bool
}

// NewTTYGraphics creates a new TTYGraphics backed by the given TTY writer.
func NewTTYGraphics(writer *tty.Writer) *TTYGraphics {
	return &TTYGraphics{
		writer: writer,
		inTmux: writer.InTmux(),
	}
}

func (g *TTYGraphics) Transmit(id uint32, data []byte, format string, width, height int) error {
	cmd := kitty.TransmitCommand{
		ImageID: id,
		Format:  format,
		Width:   width,
		Height:  height,
	}
	if g.inTmux {
		// Wrap each chunk individually — tmux DCS passthrough has size limits
		chunks := cmd.SerializeChunks(data)
		for i, chunk := range chunks {
			chunks[i] = kitty.WrapTmux(chunk)
		}
		g.writer.Writes <- []byte(strings.Join(chunks, ""))
	} else {
		g.writer.Writes <- []byte(cmd.Serialize(data))
	}
	return nil
}

func (g *TTYGraphics) Place(imageID, placementID uint32, row, col int, p PlacementInfo) error {
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
	seq := cmd.Serialize()
	if g.inTmux {
		seq = kitty.WrapTmux(seq)
	}
	g.writer.Writes <- []byte(seq)
	return nil
}

func (g *TTYGraphics) Delete(imageID, placementID uint32, free bool) error {
	cmd := kitty.DeleteCommand{
		ImageID:     imageID,
		PlacementID: placementID,
		Free:        free,
	}
	seq := cmd.Serialize()
	if g.inTmux {
		seq = kitty.WrapTmux(seq)
	}
	g.writer.Writes <- []byte(seq)
	return nil
}
