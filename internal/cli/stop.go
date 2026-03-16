package cli

import (
	"context"
	"fmt"

	"github.com/joshheyse/kgd/pkg/kgdclient"
	"github.com/spf13/cobra"
)

var stopCmd = &cobra.Command{
	Use:   "stop",
	Short: "Stop the kgd daemon",
	RunE: func(cmd *cobra.Command, args []string) error {
		client, err := kgdclient.Connect(context.Background(), kgdclient.Options{
			ClientType: "cli",
			Label:      "kgd stop",
		})
		if err != nil {
			return fmt.Errorf("connecting to daemon: %w", err)
		}
		defer client.Close()

		return client.Stop()
	},
}
