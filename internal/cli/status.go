package cli

import (
	"context"
	"fmt"

	"github.com/joshheyse/kgd/pkg/kgdclient"
	"github.com/spf13/cobra"
)

var statusCmd = &cobra.Command{
	Use:   "status",
	Short: "Show daemon status",
	RunE: func(cmd *cobra.Command, args []string) error {
		client, err := kgdclient.Connect(context.Background(), kgdclient.Options{
			ClientType: "cli",
			Label:      "kgd status",
		})
		if err != nil {
			return fmt.Errorf("connecting to daemon: %w", err)
		}
		defer client.Close()

		status, err := client.Status(context.Background())
		if err != nil {
			return fmt.Errorf("getting status: %w", err)
		}

		fmt.Printf("Clients:    %d\n", status.Clients)
		fmt.Printf("Placements: %d\n", status.Placements)
		fmt.Printf("Images:     %d\n", status.Images)
		fmt.Printf("Terminal:   %dx%d\n", status.Cols, status.Rows)
		return nil
	},
}
