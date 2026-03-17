package cli

import (
	"fmt"
	"os"

	"github.com/joshheyse/kgd/pkg/kgdsocket"
	"github.com/spf13/cobra"
)

var initCmd = &cobra.Command{
	Use:   "init",
	Short: "Start daemon if needed and print shell exports",
	Long:  "Ensures the kgd daemon is running and prints export statements for KGD_SOCKET.",
	RunE: func(cmd *cobra.Command, args []string) error {
		socketPath := os.Getenv("KGD_SOCKET")
		if socketPath == "" {
			socketPath = kgdsocket.DefaultPath()
		}

		if err := kgdsocket.EnsureDaemon(socketPath); err != nil {
			return err
		}

		fmt.Printf("export KGD_SOCKET=%s\n", socketPath)
		return nil
	},
}
