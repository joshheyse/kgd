package kitty

import (
	"encoding/base64"
	"fmt"
	"strings"
)

const (
	chunkSize = 4096 // kitty protocol max chunk size for base64 data
)

// TransmitCommand builds a kitty graphics protocol transmit (upload) command.
type TransmitCommand struct {
	ImageID uint32
	Format  string // "png" (f=100), "rgb" (f=24), "rgba" (f=32)
	Width   int
	Height  int
}

// Serialize encodes the transmit command with the given base64 data.
// For data larger than 4096 bytes, it produces chunked APC sequences.
func (c TransmitCommand) Serialize(data []byte) string {
	return strings.Join(c.SerializeChunks(data), "")
}

// SerializeChunks returns individual APC sequences, one per chunk.
// Use this when each chunk needs independent wrapping (e.g., tmux DCS passthrough).
func (c TransmitCommand) SerializeChunks(data []byte) []string {
	b64 := base64.StdEncoding.EncodeToString(data)
	format := formatCode(c.Format)

	if len(b64) <= chunkSize {
		return []string{fmt.Sprintf("\x1b_Ga=t,f=%d,i=%d,s=%d,v=%d;%s\x1b\\",
			format, c.ImageID, c.Width, c.Height, b64)}
	}

	chunks := splitChunks(b64, chunkSize)
	result := make([]string, len(chunks))
	for i, chunk := range chunks {
		more := 1
		if i == len(chunks)-1 {
			more = 0
		}
		if i == 0 {
			result[i] = fmt.Sprintf("\x1b_Ga=t,f=%d,i=%d,s=%d,v=%d,m=%d;%s\x1b\\",
				format, c.ImageID, c.Width, c.Height, more, chunk)
		} else {
			result[i] = fmt.Sprintf("\x1b_Gm=%d;%s\x1b\\", more, chunk)
		}
	}
	return result
}

// PlaceCommand builds a kitty graphics protocol placement command.
type PlaceCommand struct {
	ImageID     uint32
	PlacementID uint32
	Row         int
	Col         int
	Width       int // columns
	Height      int // rows
	SrcX        int
	SrcY        int
	SrcW        int
	SrcH        int
	ZIndex      int32
}

// Serialize encodes the placement command as a kitty APC sequence.
func (c PlaceCommand) Serialize() string {
	var parts []string
	parts = append(parts, "a=p")
	parts = append(parts, fmt.Sprintf("i=%d", c.ImageID))
	if c.PlacementID != 0 {
		parts = append(parts, fmt.Sprintf("p=%d", c.PlacementID))
	}
	if c.Width > 0 {
		parts = append(parts, fmt.Sprintf("c=%d", c.Width))
	}
	if c.Height > 0 {
		parts = append(parts, fmt.Sprintf("r=%d", c.Height))
	}
	if c.SrcX > 0 {
		parts = append(parts, fmt.Sprintf("x=%d", c.SrcX))
	}
	if c.SrcY > 0 {
		parts = append(parts, fmt.Sprintf("y=%d", c.SrcY))
	}
	if c.SrcW > 0 {
		parts = append(parts, fmt.Sprintf("w=%d", c.SrcW))
	}
	if c.SrcH > 0 {
		parts = append(parts, fmt.Sprintf("h=%d", c.SrcH))
	}
	if c.ZIndex != 0 {
		parts = append(parts, fmt.Sprintf("z=%d", c.ZIndex))
	}

	return fmt.Sprintf("\x1b[%d;%dH\x1b_G%s;\x1b\\", c.Row+1, c.Col+1, strings.Join(parts, ","))
}

// DeleteCommand builds a kitty graphics protocol delete command.
type DeleteCommand struct {
	ImageID     uint32
	PlacementID uint32
	Free        bool // if true, also free the stored image data
}

// Serialize encodes the delete command as a kitty APC sequence.
func (c DeleteCommand) Serialize() string {
	deleteType := "d=i"
	if c.Free {
		deleteType = "d=I"
	}

	if c.PlacementID != 0 {
		return fmt.Sprintf("\x1b_Ga=d,%s,i=%d,p=%d;\x1b\\", deleteType, c.ImageID, c.PlacementID)
	}
	return fmt.Sprintf("\x1b_Ga=d,%s,i=%d;\x1b\\", deleteType, c.ImageID)
}

// WrapTmux wraps a kitty APC escape sequence in a tmux DCS passthrough,
// doubling ESC bytes as required by tmux.
func WrapTmux(escape string) string {
	// tmux requires ESC within DCS to be doubled
	inner := strings.ReplaceAll(escape, "\x1b", "\x1b\x1b")
	return "\x1bPtmux;" + inner + "\x1b\\"
}

// CursorPosition returns the escape sequence to move the cursor to (row, col).
// Row and col are 1-based.
func CursorPosition(row, col int) string {
	return fmt.Sprintf("\x1b[%d;%dH", row, col)
}

func formatCode(format string) int {
	switch format {
	case "rgb":
		return 24
	case "rgba":
		return 32
	default: // png
		return 100
	}
}

func splitChunks(s string, size int) []string {
	var chunks []string
	for len(s) > 0 {
		end := size
		if end > len(s) {
			end = len(s)
		}
		chunks = append(chunks, s[:end])
		s = s[end:]
	}
	return chunks
}
