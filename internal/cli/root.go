package cli

import (
	"github.com/spf13/cobra"
)

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
