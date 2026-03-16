package tty

import (
	"fmt"
	"os"
	"strings"
	"time"
)

// TermColors holds the terminal's foreground and background colors.
type TermColors struct {
	FG Color16
	BG Color16
}

// Color16 represents an RGB color with 16-bit per channel precision.
type Color16 struct {
	R, G, B uint16
}

// QueryColors queries the terminal's foreground (OSC 10) and background (OSC 11)
// colors by writing escape sequences and parsing responses.
// Returns zero colors if the terminal doesn't respond within the timeout.
func QueryColors(ttyFile *os.File, inTmux bool) TermColors {
	var colors TermColors

	// Build query: OSC 10 ? ST + OSC 11 ? ST
	query := "\x1b]10;?\x1b\\\x1b]11;?\x1b\\"
	if inTmux {
		// tmux requires DCS passthrough with doubled ESC
		query = "\x1bPtmux;\x1b\x1b]10;?\x1b\x1b\\\x1b\\\x1bPtmux;\x1b\x1b]11;?\x1b\x1b\\\x1b\\"
	}

	if _, err := ttyFile.Write([]byte(query)); err != nil {
		return colors
	}

	// Read responses with timeout
	buf := make([]byte, 256)
	if err := ttyFile.SetReadDeadline(time.Now().Add(200 * time.Millisecond)); err != nil {
		return colors
	}
	defer ttyFile.SetReadDeadline(time.Time{})

	var response strings.Builder
	for {
		n, err := ttyFile.Read(buf)
		if n > 0 {
			response.Write(buf[:n])
		}
		if err != nil {
			break
		}
		// Check if we've received both responses
		if strings.Count(response.String(), "rgb:") >= 2 {
			break
		}
	}

	// Parse responses
	colors.FG = parseOSCColor(response.String(), "10")
	colors.BG = parseOSCColor(response.String(), "11")
	return colors
}

// parseOSCColor extracts a color from an OSC response string.
// The response format is: ESC ] <num> ; rgb:RRRR/GGGG/BBBB ST
func parseOSCColor(response, oscNum string) Color16 {
	// Look for pattern: ]<num>;rgb:
	prefix := fmt.Sprintf("]%s;rgb:", oscNum)
	idx := strings.Index(response, prefix)
	if idx < 0 {
		return Color16{}
	}
	rest := response[idx+len(prefix):]

	// Find the string terminator (BEL or ST)
	end := strings.IndexAny(rest, "\x07\x1b\\")
	if end < 0 {
		end = len(rest)
	}
	colorStr := rest[:end]

	return ParseRGBColor(colorStr)
}

// ParseRGBColor parses a color string in the format "RRRR/GGGG/BBBB" or "RR/GG/BB".
// Returns zero Color16 on parse failure.
func ParseRGBColor(s string) Color16 {
	parts := strings.Split(s, "/")
	if len(parts) != 3 {
		return Color16{}
	}

	r := parseHex16(parts[0])
	g := parseHex16(parts[1])
	b := parseHex16(parts[2])
	return Color16{R: r, G: g, B: b}
}

// parseHex16 parses a hex string and normalizes to 16-bit.
// Handles 1, 2, 3, or 4 hex digit formats. Returns 0 on invalid input.
func parseHex16(s string) uint16 {
	if len(s) == 0 || len(s) > 4 {
		return 0
	}
	var val uint64
	for _, c := range s {
		var d uint64
		switch {
		case c >= '0' && c <= '9':
			d = uint64(c - '0')
		case c >= 'a' && c <= 'f':
			d = uint64(c - 'a' + 10)
		case c >= 'A' && c <= 'F':
			d = uint64(c - 'A' + 10)
		default:
			return 0
		}
		val = val<<4 | d
	}

	// Normalize to 16-bit based on input length
	switch len(s) {
	case 1:
		return uint16(val * 0x1111)
	case 2:
		return uint16(val * 0x0101)
	case 3:
		return uint16((val << 4) | (val >> 8))
	case 4:
		return uint16(val)
	default:
		return 0
	}
}
