package cli

import (
	"fmt"
	"os"

	"github.com/joshheyse/kgd/internal/daemon"
	"github.com/spf13/cobra"
)

var diagnoseCmd = &cobra.Command{
	Use:   "diagnose",
	Short: "Show terminal detection info",
	RunE: func(cmd *cobra.Command, args []string) error {
		fmt.Printf("TERM:            %s\n", os.Getenv("TERM"))
		fmt.Printf("TERM_PROGRAM:    %s\n", os.Getenv("TERM_PROGRAM"))
		fmt.Printf("KITTY_WINDOW_ID: %s\n", os.Getenv("KITTY_WINDOW_ID"))
		fmt.Printf("WEZTERM_PANE:    %s\n", os.Getenv("WEZTERM_PANE"))
		fmt.Printf("TMUX:            %s\n", os.Getenv("TMUX"))
		fmt.Printf("KGD_SOCKET:      %s\n", os.Getenv("KGD_SOCKET"))
		fmt.Printf("KGD_SESSION:     %s\n", os.Getenv("KGD_SESSION"))
		fmt.Printf("XDG_RUNTIME_DIR: %s\n", os.Getenv("XDG_RUNTIME_DIR"))
		fmt.Printf("Socket path:     %s\n", daemon.DefaultSocketPath())
		return nil
	},
}
