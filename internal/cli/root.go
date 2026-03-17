package cli

import (
	"fmt"
	"os"

	"github.com/joshheyse/kgd/pkg/kgdsocket"
	"github.com/spf13/cobra"
)

// cliSessionID returns the session ID for CLI commands.
// Uses $KGD_SESSION if set, otherwise auto-generates from the terminal session key
// so that all CLI invocations in the same terminal share state.
func cliSessionID() string {
	if id := os.Getenv("KGD_SESSION"); id != "" {
		return id
	}
	return fmt.Sprintf("cli-%s", kgdsocket.SessionKey())
}

var rootCmd = &cobra.Command{
	Use:   "kgd",
	Short: "Kitty Graphics Daemon",
	Long:  "kgd is a user-space daemon that owns all kitty graphics protocol output for a terminal session, providing a unified, topology-aware placement service to any client.",
}

func Execute() error {
	return rootCmd.Execute()
}

func init() {
	rootCmd.AddCommand(serveCmd)
	rootCmd.AddCommand(initCmd)
	rootCmd.AddCommand(stopCmd)
	rootCmd.AddCommand(uploadCmd)
	rootCmd.AddCommand(placeCmd)
	rootCmd.AddCommand(unplaceCmd)
	rootCmd.AddCommand(listCmd)
	rootCmd.AddCommand(statusCmd)
	rootCmd.AddCommand(diagnoseCmd)
}
