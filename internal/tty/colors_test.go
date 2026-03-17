package tty

import "testing"

func TestParseRGBColor(t *testing.T) {
	tests := []struct {
		name  string
		input string
		want  Color16
	}{
		{
			name:  "4-digit hex",
			input: "ffff/ffff/ffff",
			want:  Color16{R: 0xFFFF, G: 0xFFFF, B: 0xFFFF},
		},
		{
			name:  "4-digit hex black",
			input: "0000/0000/0000",
			want:  Color16{R: 0, G: 0, B: 0},
		},
		{
			name:  "2-digit hex",
			input: "ff/00/80",
			want:  Color16{R: 0xFF * 0x0101, G: 0, B: 0x80 * 0x0101},
		},
		{
			name:  "typical terminal response",
			input: "3a3a/4242/5050",
			want:  Color16{R: 0x3A3A, G: 0x4242, B: 0x5050},
		},
		{
			name:  "1-digit hex",
			input: "f/0/8",
			want:  Color16{R: 0xFFFF, G: 0, B: 0x8888},
		},
		{
			name:  "3-digit hex",
			input: "abc/def/123",
			want:  Color16{R: 0xABCA, G: 0xDEFD, B: 0x1231},
		},
		{
			name:  "empty",
			input: "",
			want:  Color16{},
		},
		{
			name:  "invalid chars",
			input: "zzzz/yyyy/xxxx",
			want:  Color16{},
		},
		{
			name:  "too many parts",
			input: "ff/ff/ff/ff",
			want:  Color16{},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := ParseRGBColor(tt.input)
			if got != tt.want {
				t.Errorf("ParseRGBColor(%q) = %+v, want %+v", tt.input, got, tt.want)
			}
		})
	}
}

func TestParseOSCColor(t *testing.T) {
	tests := []struct {
		name     string
		response string
		oscNum   string
		want     Color16
	}{
		{
			name:     "OSC 10 response",
			response: "\x1b]10;rgb:ffff/ffff/ffff\x1b\\",
			oscNum:   "10",
			want:     Color16{R: 0xFFFF, G: 0xFFFF, B: 0xFFFF},
		},
		{
			name:     "OSC 11 response",
			response: "\x1b]11;rgb:0000/0000/0000\x1b\\",
			oscNum:   "11",
			want:     Color16{R: 0, G: 0, B: 0},
		},
		{
			name:     "both OSC 10 and 11",
			response: "\x1b]10;rgb:ffff/ffff/ffff\x1b\\\x1b]11;rgb:1a1a/2b2b/3c3c\x1b\\",
			oscNum:   "11",
			want:     Color16{R: 0x1A1A, G: 0x2B2B, B: 0x3C3C},
		},
		{
			name:     "BEL terminator",
			response: "\x1b]10;rgb:aaaa/bbbb/cccc\x07",
			oscNum:   "10",
			want:     Color16{R: 0xAAAA, G: 0xBBBB, B: 0xCCCC},
		},
		{
			name:     "no response",
			response: "",
			oscNum:   "10",
			want:     Color16{},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := parseOSCColor(tt.response, tt.oscNum)
			if got != tt.want {
				t.Errorf("parseOSCColor(%q, %q) = %+v, want %+v", tt.response, tt.oscNum, got, tt.want)
			}
		})
	}
}
