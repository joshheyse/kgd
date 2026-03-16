package cli

import (
	"fmt"
	"net"
	"os"
	"os/exec"
	"syscall"
	"time"

	"github.com/joshheyse/kgd/internal/daemon"
	"github.com/spf13/cobra"
)

var initCmd = &cobra.Command{
	Use:   "init",
	Short: "Start daemon if needed and print shell exports",
	Long:  "Ensures the kgd daemon is running and prints export statements for KGD_SOCKET.",
	RunE: func(cmd *cobra.Command, args []string) error {
		socketPath := os.Getenv("KGD_SOCKET")
		if socketPath == "" {
			socketPath = daemon.DefaultSocketPath()
		}

		// Check if daemon is already running
		conn, err := net.Dial("unix", socketPath)
		if err == nil {
			conn.Close()
			fmt.Printf("export KGD_SOCKET=%s\n", socketPath)
			return nil
		}

		// Start daemon
		kgdPath, err := os.Executable()
		if err != nil {
			kgdPath, err = exec.LookPath("kgd")
			if err != nil {
				return fmt.Errorf("cannot find kgd binary: %w", err)
			}
		}

		daemonCmd := exec.Command(kgdPath, "serve", "--socket", socketPath)
		daemonCmd.Stdout = nil
		daemonCmd.Stderr = nil
		daemonCmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
		if err := daemonCmd.Start(); err != nil {
			return fmt.Errorf("starting daemon: %w", err)
		}
		// Detach: the child runs in its own session, no need to wait
		go daemonCmd.Wait()

		// Wait for socket
		for range 50 {
			time.Sleep(100 * time.Millisecond)
			if conn, err := net.Dial("unix", socketPath); err == nil {
				conn.Close()
				fmt.Printf("export KGD_SOCKET=%s\n", socketPath)
				return nil
			}
		}

		return fmt.Errorf("timed out waiting for daemon to start")
	},
}
