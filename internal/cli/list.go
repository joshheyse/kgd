package cli

import (
	"context"
	"fmt"

	"github.com/joshheyse/kgd/pkg/kgdclient"
	"github.com/spf13/cobra"
)

var listCmd = &cobra.Command{
	Use:   "list",
	Short: "List active placements",
	RunE: func(cmd *cobra.Command, args []string) error {
		client, err := kgdclient.Connect(context.Background(), kgdclient.Options{
			ClientType: "cli",
			Label:      "kgd list",
			SessionID:  cliSessionID(),
		})
		if err != nil {
			return fmt.Errorf("connecting to daemon: %w", err)
		}
		defer client.Close()

		result, err := client.List(context.Background())
		if err != nil {
			return fmt.Errorf("listing: %w", err)
		}

		if len(result.Placements) == 0 {
			fmt.Println("No active placements.")
			return nil
		}

		fmt.Printf("%-12s %-36s %-8s %-8s %-5s %-5s\n", "PLACEMENT", "CLIENT", "HANDLE", "VISIBLE", "ROW", "COL")
		for _, p := range result.Placements {
			fmt.Printf("%-12d %-36s %-8d %-8v %-5d %-5d\n",
				p.PlacementID, p.ClientID, p.Handle, p.Visible, p.Row, p.Col)
		}
		return nil
	},
}
