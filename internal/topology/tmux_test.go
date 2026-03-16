package topology

import (
	"testing"

	"github.com/joshheyse/kgd/internal/engine"
)

func TestParsePaneLine(t *testing.T) {
	tests := []struct {
		name    string
		input   string
		want    engine.PaneGeometry
		wantErr bool
	}{
		{
			name:  "basic pane",
			input: "%0 0 0 80 24 1",
			want:  engine.PaneGeometry{ID: "%0", Top: 0, Left: 0, Width: 80, Height: 24, Active: true},
		},
		{
			name:  "split pane top",
			input: "%1 0 0 80 12 1",
			want:  engine.PaneGeometry{ID: "%1", Top: 0, Left: 0, Width: 80, Height: 12, Active: true},
		},
		{
			name:  "split pane bottom",
			input: "%2 13 0 80 11 1",
			want:  engine.PaneGeometry{ID: "%2", Top: 13, Left: 0, Width: 80, Height: 11, Active: true},
		},
		{
			name:  "inactive window pane",
			input: "%3 0 0 80 24 0",
			want:  engine.PaneGeometry{ID: "%3", Top: 0, Left: 0, Width: 80, Height: 24, Active: false},
		},
		{
			name:  "without active field (legacy)",
			input: "%0 5 10 40 20",
			want:  engine.PaneGeometry{ID: "%0", Top: 5, Left: 10, Width: 40, Height: 20, Active: true},
		},
		{
			name:    "too few fields",
			input:   "%0 0 0",
			wantErr: true,
		},
		{
			name:    "non-numeric field",
			input:   "%0 abc 0 80 24 1",
			wantErr: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := parsePaneLine(tt.input)
			if tt.wantErr {
				if err == nil {
					t.Fatal("expected error")
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if got != tt.want {
				t.Errorf("got %+v, want %+v", got, tt.want)
			}
		})
	}
}

func TestShouldRefreshPanes(t *testing.T) {
	tests := []struct {
		line string
		want bool
	}{
		{"%layout-change @0 abcd,80x24,0,0", true},
		{"%window-pane-changed @0 %1", true},
		{"%session-window-changed $0 @1", true},
		{"%window-add @2", true},
		{"%window-close @1", true},
		{"%unlinked-window-add @3", true},
		{"%unlinked-window-close @3", true},
		{"%output %0 hello", false},
		{"%begin 12345", false},
		{"some random text", false},
	}

	for _, tt := range tests {
		got := shouldRefreshPanes(tt.line)
		if got != tt.want {
			t.Errorf("shouldRefreshPanes(%q) = %v, want %v", tt.line, got, tt.want)
		}
	}
}
