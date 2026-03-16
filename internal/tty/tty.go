package tty

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"syscall"

	"golang.org/x/sys/unix"
)

// WinSize holds terminal dimensions from TIOCGWINSZ.
type WinSize struct {
	Rows   uint16
	Cols   uint16
	XPixel uint16
	YPixel uint16
}

// Writer is the sole goroutine that writes to /dev/tty.
// All other goroutines send batched writes via the Writes channel.
type Writer struct {
	Writes chan []byte
	Size   chan WinSize
	Colors chan TermColors

	ttyFile *os.File
	inTmux  bool
}

// NewWriter opens /dev/tty and queries its initial size.
func NewWriter() (*Writer, error) {
	f, err := os.OpenFile("/dev/tty", os.O_RDWR, 0)
	if err != nil {
		return nil, err
	}

	w := &Writer{
		Writes:  make(chan []byte, 64),
		Size:    make(chan WinSize, 4),
		Colors:  make(chan TermColors, 2),
		ttyFile: f,
		inTmux:  os.Getenv("TMUX") != "",
	}

	return w, nil
}

// InTmux returns whether the session is inside tmux.
func (w *Writer) InTmux() bool {
	return w.inTmux
}

// Close closes the TTY file descriptor. Safe to call if Run() was never called.
func (w *Writer) Close() error {
	if w.ttyFile != nil {
		return w.ttyFile.Close()
	}
	return nil
}

// QuerySize queries the current terminal dimensions via TIOCGWINSZ.
func (w *Writer) QuerySize() (WinSize, error) {
	ws, err := unix.IoctlGetWinsize(int(w.ttyFile.Fd()), unix.TIOCGWINSZ)
	if err != nil {
		return WinSize{}, err
	}
	return WinSize{
		Rows:   ws.Row,
		Cols:   ws.Col,
		XPixel: ws.Xpixel,
		YPixel: ws.Ypixel,
	}, nil
}

// Run processes write requests and SIGWINCH signals until ctx is cancelled.
func (w *Writer) Run(ctx context.Context) {
	slog.Info("tty writer started", "tmux", w.inTmux)
	defer slog.Info("tty writer stopped")
	defer w.ttyFile.Close()

	// Send initial size
	if sz, err := w.QuerySize(); err == nil {
		w.Size <- sz
		slog.Info("terminal size", "rows", sz.Rows, "cols", sz.Cols,
			"xpixel", sz.XPixel, "ypixel", sz.YPixel)
	}

	// Query initial colors
	colors := QueryColors(w.ttyFile, w.inTmux)
	if colors.FG != (Color16{}) || colors.BG != (Color16{}) {
		w.Colors <- colors
		slog.Info("terminal colors",
			"fg", fmt.Sprintf("#%04x%04x%04x", colors.FG.R, colors.FG.G, colors.FG.B),
			"bg", fmt.Sprintf("#%04x%04x%04x", colors.BG.R, colors.BG.G, colors.BG.B))
	}

	// Listen for SIGWINCH
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGWINCH)
	defer signal.Stop(sigCh)

	fd := int(w.ttyFile.Fd())

	for {
		select {
		case <-ctx.Done():
			return
		case buf := <-w.Writes:
			// Write entire buffer to TTY
			for len(buf) > 0 {
				n, err := unix.Write(fd, buf)
				if err != nil {
					slog.Error("tty write failed", "error", err)
					break
				}
				buf = buf[n:]
			}
		case <-sigCh:
			if sz, err := w.QuerySize(); err == nil {
				slog.Info("terminal resized", "rows", sz.Rows, "cols", sz.Cols,
					"xpixel", sz.XPixel, "ypixel", sz.YPixel)
				select {
				case w.Size <- sz:
				default:
				}
			}
			// Re-query colors (theme may have changed)
			newColors := QueryColors(w.ttyFile, w.inTmux)
			if newColors.FG != (Color16{}) || newColors.BG != (Color16{}) {
				select {
				case w.Colors <- newColors:
				default:
				}
			}
		}
	}
}
