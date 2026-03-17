// Package kgdsocket provides shared socket path computation for daemon and clients.
package kgdsocket

import (
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

// DefaultPath returns the default socket path for the current terminal session.
func DefaultPath() string {
	runtimeDir := os.Getenv("XDG_RUNTIME_DIR")
	if runtimeDir == "" {
		runtimeDir = os.TempDir()
	}
	return filepath.Join(runtimeDir, fmt.Sprintf("kgd-%s.sock", SessionKey()))
}

// SessionKey computes a unique key for this terminal session.
// Priority: $KITTY_WINDOW_ID → $WEZTERM_PANE → TTY device path → "default"
func SessionKey() string {
	if id := os.Getenv("KITTY_WINDOW_ID"); id != "" {
		return "kitty-" + id
	}
	if id := os.Getenv("WEZTERM_PANE"); id != "" {
		return "wezterm-" + id
	}
	// Fall back to TTY device path
	ttyPath := ttyDevicePath()
	if ttyPath != "" {
		safe := strings.ReplaceAll(ttyPath, "/", "-")
		safe = strings.TrimPrefix(safe, "-dev-")
		return "tty-" + safe
	}
	return "default"
}

// EnsureDaemon starts the kgd daemon if it's not already running on the given socket.
// It will find the kgd binary via os.Executable() or PATH, start it in a new session,
// and wait up to 5 seconds for the socket to become available.
func EnsureDaemon(socketPath string) error {
	// Check if daemon is already running
	conn, err := net.Dial("unix", socketPath)
	if err == nil {
		conn.Close()
		return nil
	}

	// Find kgd binary — prefer current executable, fall back to PATH
	kgdPath, err := os.Executable()
	if err != nil {
		kgdPath, err = exec.LookPath("kgd")
		if err != nil {
			return fmt.Errorf("kgd not found: %w", err)
		}
	}

	// Fork+exec in its own session
	cmd := exec.Command(kgdPath, "serve", "--socket", socketPath)
	cmd.Stdout = nil
	cmd.Stderr = nil
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("starting kgd: %w", err)
	}
	go cmd.Wait() // reap child asynchronously

	// Wait for socket to become available
	for range 50 {
		time.Sleep(100 * time.Millisecond)
		if conn, err := net.Dial("unix", socketPath); err == nil {
			conn.Close()
			return nil
		}
	}

	return fmt.Errorf("timed out waiting for kgd daemon to start")
}

// ttyDevicePath returns the path to the controlling terminal, or empty string.
func ttyDevicePath() string {
	// Read /proc/self/fd/0 symlink (Linux) or use os.Stdin stat (macOS)
	if target, err := os.Readlink("/proc/self/fd/0"); err == nil {
		if strings.HasPrefix(target, "/dev/") {
			return target
		}
	}
	// Fallback: check if stdin is a terminal
	if fi, err := os.Stdin.Stat(); err == nil {
		if fi.Mode()&os.ModeCharDevice != 0 {
			return fi.Name()
		}
	}
	return ""
}
