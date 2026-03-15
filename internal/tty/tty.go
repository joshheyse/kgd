package tty

import (
	"context"
	"log/slog"
)

// Writer is the sole goroutine that writes to /dev/tty.
// All other goroutines send batched writes via the Writes channel.
type Writer struct {
	Writes chan []byte
}

// NewWriter creates a new TTY writer.
func NewWriter() *Writer {
	return &Writer{
		Writes: make(chan []byte, 64),
	}
}

// Run processes write requests until ctx is cancelled. Must be called as a goroutine.
func (w *Writer) Run(ctx context.Context) {
	slog.Info("tty writer started")
	defer slog.Info("tty writer stopped")

	// TODO: open /dev/tty, handle SIGWINCH via TIOCGWINSZ

	for {
		select {
		case <-ctx.Done():
			return
		case buf := <-w.Writes:
			// TODO: write to /dev/tty fd
			_ = buf
		}
	}
}
