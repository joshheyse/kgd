package cli

import (
	"context"
	"fmt"
	"os"
	"strconv"

	"github.com/joshheyse/kgd/internal/protocol"
	"github.com/joshheyse/kgd/pkg/kgdclient"
	"github.com/spf13/cobra"
)

var (
	placeRow    int
	placeCol    int
	placeWidth  int
	placeHeight int
)

var placeCmd = &cobra.Command{
	Use:   "place <handle>",
	Short: "Place an image at a position",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		handle, err := strconv.ParseUint(args[0], 10, 32)
		if err != nil {
			return fmt.Errorf("invalid handle: %w", err)
		}

		client, err := kgdclient.Connect(context.Background(), kgdclient.Options{
			ClientType: "cli",
			Label:      "kgd place",
			SessionID:  os.Getenv("KGD_SESSION"),
		})
		if err != nil {
			return fmt.Errorf("connecting to daemon: %w", err)
		}
		defer client.Close()

		pid, err := client.Place(context.Background(), uint32(handle), protocol.Anchor{
			Type: "absolute",
			Row:  placeRow,
			Col:  placeCol,
		}, placeWidth, placeHeight)
		if err != nil {
			return fmt.Errorf("placing: %w", err)
		}

		fmt.Println(pid)
		return nil
	},
}

func init() {
	placeCmd.Flags().IntVar(&placeRow, "row", 0, "Terminal row")
	placeCmd.Flags().IntVar(&placeCol, "col", 0, "Terminal column")
	placeCmd.Flags().IntVar(&placeWidth, "width", 0, "Width in columns")
	placeCmd.Flags().IntVar(&placeHeight, "height", 0, "Height in rows")
}
