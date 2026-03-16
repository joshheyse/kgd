package cli

import (
	"context"
	"fmt"
	"os"
	"strconv"

	"github.com/joshheyse/kgd/pkg/kgdclient"
	"github.com/spf13/cobra"
)

var unplaceCmd = &cobra.Command{
	Use:   "unplace <placement_id>",
	Short: "Remove a placement",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		pid, err := strconv.ParseUint(args[0], 10, 32)
		if err != nil {
			return fmt.Errorf("invalid placement ID: %w", err)
		}

		client, err := kgdclient.Connect(context.Background(), kgdclient.Options{
			ClientType: "cli",
			Label:      "kgd unplace",
			SessionID:  os.Getenv("KGD_SESSION"),
		})
		if err != nil {
			return fmt.Errorf("connecting to daemon: %w", err)
		}
		defer client.Close()

		return client.Unplace(uint32(pid))
	},
}
