package kitty

import (
	"strings"
	"testing"
)

func TestTransmitCommandSmallPayload(t *testing.T) {
	cmd := TransmitCommand{
		ImageID: 1,
		Format:  "png",
		Width:   100,
		Height:  50,
	}

	data := []byte("test")
	result := cmd.Serialize(data)

	if !strings.HasPrefix(result, "\x1b_G") {
		t.Error("expected APC start")
	}
	if !strings.HasSuffix(result, "\x1b\\") {
		t.Error("expected ST terminator")
	}
	if !strings.Contains(result, "a=t") {
		t.Error("expected transmit action")
	}
	if !strings.Contains(result, "i=1") {
		t.Error("expected image ID")
	}
	if !strings.Contains(result, "f=100") {
		t.Error("expected PNG format code")
	}
}

func TestTransmitCommandChunking(t *testing.T) {
	cmd := TransmitCommand{
		ImageID: 2,
		Format:  "rgb",
		Width:   640,
		Height:  480,
	}

	// Create data large enough to require chunking
	data := make([]byte, 4096)
	result := cmd.Serialize(data)

	// Should have multiple APC sequences
	count := strings.Count(result, "\x1b_G")
	if count < 2 {
		t.Errorf("expected multiple chunks, got %d APC sequences", count)
	}

	// First chunk should have m=1, last should have m=0
	if !strings.Contains(result, "m=1") {
		t.Error("expected m=1 in non-final chunk")
	}
	if !strings.Contains(result, "m=0") {
		t.Error("expected m=0 in final chunk")
	}
}

func TestPlaceCommandSerialize(t *testing.T) {
	cmd := PlaceCommand{
		ImageID:     1,
		PlacementID: 42,
		Row:         10,
		Col:         5,
		Width:       20,
		Height:      10,
		ZIndex:      -1073741825,
	}

	result := cmd.Serialize()

	// Should have cursor positioning (1-based)
	if !strings.Contains(result, "\x1b[11;6H") {
		t.Errorf("expected cursor at row=11,col=6, got %q", result)
	}
	if !strings.Contains(result, "a=p") {
		t.Error("expected placement action")
	}
	if !strings.Contains(result, "i=1") {
		t.Error("expected image ID")
	}
	if !strings.Contains(result, "p=42") {
		t.Error("expected placement ID")
	}
}

func TestDeleteCommandSerialize(t *testing.T) {
	cmd := DeleteCommand{
		ImageID: 5,
		Free:    true,
	}

	result := cmd.Serialize()

	if !strings.Contains(result, "a=d") {
		t.Error("expected delete action")
	}
	if !strings.Contains(result, "d=I") {
		t.Error("expected free delete type")
	}
	if !strings.Contains(result, "i=5") {
		t.Error("expected image ID")
	}
}

func TestWrapTmux(t *testing.T) {
	input := "\x1b_Ga=t,i=1;data\x1b\\"
	result := WrapTmux(input)

	if !strings.HasPrefix(result, "\x1bPtmux;") {
		t.Error("expected tmux DCS prefix")
	}
	if !strings.HasSuffix(result, "\x1b\\") {
		t.Error("expected ST terminator")
	}
	// ESCs within should be doubled
	inner := result[len("\x1bPtmux;") : len(result)-len("\x1b\\")]
	if !strings.Contains(inner, "\x1b\x1b") {
		t.Error("expected doubled ESC bytes")
	}
}

func TestFormatCode(t *testing.T) {
	tests := []struct {
		format string
		want   int
	}{
		{"png", 100},
		{"rgb", 24},
		{"rgba", 32},
		{"unknown", 100},
	}

	for _, tt := range tests {
		got := formatCode(tt.format)
		if got != tt.want {
			t.Errorf("formatCode(%q) = %d, want %d", tt.format, got, tt.want)
		}
	}
}
