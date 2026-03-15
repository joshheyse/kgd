package logging

import (
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
)

// Setup configures the default slog logger to write to both stderr and logFile.
// If logFile is empty, a default path under $XDG_STATE_HOME/kgd/ is used.
// Returns the log file for deferred close.
func Setup(level string, logFile string) (*os.File, error) {
	if logFile == "" {
		logFile = defaultLogPath()
	}

	lvl := parseLevel(level)

	if err := os.MkdirAll(filepath.Dir(logFile), 0o755); err != nil {
		return nil, fmt.Errorf("creating log directory: %w", err)
	}

	f, err := os.OpenFile(logFile, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return nil, fmt.Errorf("opening log file %s: %w", logFile, err)
	}

	w := io.MultiWriter(os.Stderr, f)
	handler := slog.NewTextHandler(w, &slog.HandlerOptions{Level: lvl})
	slog.SetDefault(slog.New(handler))

	return f, nil
}

func defaultLogPath() string {
	stateHome := os.Getenv("XDG_STATE_HOME")
	if stateHome == "" {
		home, _ := os.UserHomeDir()
		stateHome = filepath.Join(home, ".local", "state")
	}
	return filepath.Join(stateHome, "kgd", "kgd.log")
}

func parseLevel(s string) slog.Level {
	switch strings.ToLower(s) {
	case "debug":
		return slog.LevelDebug
	case "warn", "warning":
		return slog.LevelWarn
	case "error":
		return slog.LevelError
	default:
		return slog.LevelInfo
	}
}
