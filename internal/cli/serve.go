package cli

import (
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"syscall"

	"github.com/joshheyse/kgd/internal/daemon"
	"github.com/joshheyse/kgd/internal/logging"
	"github.com/spf13/cobra"
)

var (
	logLevel  string
	logFile   string
	logStderr bool
	socket    string
)

var serveCmd = &cobra.Command{
	Use:   "serve",
	Short: "Start the kgd daemon",
	RunE: func(cmd *cobra.Command, args []string) error {
		f, err := logging.Setup(logLevel, logFile, logStderr)
		if err != nil {
			return fmt.Errorf("setting up logging: %w", err)
		}
		defer f.Close()

		slog.Info("kgd daemon starting", "pid", os.Getpid(), "socket", socket)

		d, err := daemon.New(daemon.Config{
			SocketPath: socket,
		})
		if err != nil {
			return fmt.Errorf("creating daemon: %w", err)
		}

		ctx, stop := signal.NotifyContext(cmd.Context(), syscall.SIGINT, syscall.SIGTERM)
		defer stop()

		if err := d.Run(ctx); err != nil {
			return fmt.Errorf("running daemon: %w", err)
		}

		return nil
	},
}

func init() {
	serveCmd.Flags().StringVar(&logLevel, "log-level", "info", "Log level (debug, info, warn, error)")
	serveCmd.Flags().StringVar(&logFile, "log-file", "", "Log file path (default: $XDG_STATE_HOME/kgd/kgd.log)")
	serveCmd.Flags().BoolVar(&logStderr, "log-stderr", false, "Also log to stderr")
	serveCmd.Flags().StringVar(&socket, "socket", "", "Socket path (default: $XDG_RUNTIME_DIR/kgd-$KITTY_WINDOW_ID.sock)")
}
