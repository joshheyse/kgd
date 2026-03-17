package cli

import (
	"context"
	"fmt"
	"os"

	"github.com/joshheyse/kgd/pkg/kgdclient"

	"github.com/spf13/cobra"
)

var uploadCmd = &cobra.Command{
	Use:   "upload <file>",
	Short: "Upload an image file and print the handle",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		data, err := os.ReadFile(args[0])
		if err != nil {
			return fmt.Errorf("reading file: %w", err)
		}

		client, err := kgdclient.Connect(context.Background(), kgdclient.Options{
			ClientType: "cli",
			Label:      "kgd upload",
			SessionID:  cliSessionID(),
		})
		if err != nil {
			return fmt.Errorf("connecting to daemon: %w", err)
		}
		defer client.Close()

		handle, err := client.Upload(context.Background(), data, "png", 0, 0)
		if err != nil {
			return fmt.Errorf("uploading: %w", err)
		}

		fmt.Println(handle)
		return nil
	},
}
