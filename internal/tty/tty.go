package tty

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"sync"
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

// Writer is the sole goroutine that writes to the terminal.
// All other goroutines send batched writes via the Writes channel.
//
// Each message on the Writes channel is written as a single unix.Write() call.
// In tmux, callers must send each DCS-wrapped chunk as a separate message
// to ensure atomic writes that won't interleave with shell output.
type Writer struct {
	Writes chan []byte
	Size   chan WinSize
	Colors chan TermColors

	ttyFile   *os.File
	closeOnce sync.Once
	inTmux    bool
	debugFile *os.File // if set, tee all writes here for debugging
}

// NewWriter opens /dev/tty for terminal I/O.
func NewWriter() (*Writer, error) {
	f, err := os.OpenFile("/dev/tty", os.O_RDWR, 0)
	if err != nil {
		return nil, err
	}

	w := &Writer{
		Writes:  make(chan []byte, 256),
		Size:    make(chan WinSize, 4),
		Colors:  make(chan TermColors, 2),
		ttyFile: f,
		inTmux:  os.Getenv("TMUX") != "",
	}

	// Debug: tee all TTY writes to a file for inspection
	if debugPath := os.Getenv("KGD_TTY_DEBUG"); debugPath != "" {
		df, err := os.Create(debugPath)
		if err != nil {
			slog.Warn("failed to create TTY debug file", "path", debugPath, "error", err)
		} else {
			w.debugFile = df
			slog.Info("TTY debug output enabled", "path", debugPath)
		}
	}

	return w, nil
}

// InTmux returns whether the session is inside tmux.
func (w *Writer) InTmux() bool {
	return w.inTmux
}

// Close closes the TTY file descriptors. Safe to call multiple times.
func (w *Writer) Close() error {
	var err error
	w.closeOnce.Do(func() {
		if w.debugFile != nil {
			w.debugFile.Close()
		}
		if w.ttyFile != nil {
			err = w.ttyFile.Close()
		}
	})
	return err
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
	defer w.Close()

	// Query colors BEFORE QuerySize — QuerySize calls Fd() which puts the fd
	// in blocking mode, making SetReadDeadline fail.
	colors := QueryColors(w.ttyFile, w.inTmux)
	if colors.FG != (Color16{}) || colors.BG != (Color16{}) {
		select {
		case w.Colors <- colors:
		default:
			slog.Warn("colors channel full, dropping initial colors")
		}
		slog.Info("terminal colors",
			"fg", fmt.Sprintf("#%04x%04x%04x", colors.FG.R, colors.FG.G, colors.FG.B),
			"bg", fmt.Sprintf("#%04x%04x%04x", colors.BG.R, colors.BG.G, colors.BG.B))
	}

	// Send initial size (calls Fd() internally)
	if sz, err := w.QuerySize(); err == nil {
		select {
		case w.Size <- sz:
		default:
			slog.Warn("size channel full, dropping initial size")
		}
		slog.Info("terminal size", "rows", sz.Rows, "cols", sz.Cols,
			"xpixel", sz.XPixel, "ypixel", sz.YPixel)
	}

	// Listen for SIGWINCH
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGWINCH)
	defer signal.Stop(sigCh)

	writeFd := int(w.ttyFile.Fd())
	slog.Info("tty writer fd info", "writeFd", writeFd)

	for {
		select {
		case <-ctx.Done():
			return
		case buf := <-w.Writes:
			slog.Debug("tty write", "len", len(buf), "fd", writeFd)
			if w.debugFile != nil {
				w.debugFile.Write(buf)
			}
			if len(buf) < 200 {
				slog.Debug("tty write hex", "data", fmt.Sprintf("%x", buf))
			}
			written := 0
			for len(buf) > 0 {
				n, err := unix.Write(writeFd, buf)
				if err != nil {
					slog.Error("tty write failed", "error", err, "remaining", len(buf), "written", written)
					break
				}
				written += n
				buf = buf[n:]
			}
			slog.Debug("tty write complete", "written", written)
		case <-sigCh:
			if sz, err := w.QuerySize(); err == nil {
				slog.Info("terminal resized", "rows", sz.Rows, "cols", sz.Cols,
					"xpixel", sz.XPixel, "ypixel", sz.YPixel)
				select {
				case w.Size <- sz:
				default:
					slog.Warn("size channel full, dropping resize event")
				}
			}
		}
	}
}
