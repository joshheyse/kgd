package cli

import (
	"fmt"

	"github.com/spf13/cobra"
)

var notifyEvent string

var notifyCmd = &cobra.Command{
	Use:   "notify",
	Short: "Send a notification to the running daemon",
	Long:  "Lightweight subcommand used as a tmux hook target. Connects to the daemon socket and sends a notification event.",
	RunE: func(cmd *cobra.Command, args []string) error {
		if notifyEvent == "" {
			return fmt.Errorf("--event is required")
		}

		// TODO: connect to daemon socket, send notification
		fmt.Printf("notify: event=%s\n", notifyEvent)
		return nil
	},
}

func init() {
	notifyCmd.Flags().StringVar(&notifyEvent, "event", "", "Event type (e.g. layout-changed)")
	_ = notifyCmd.MarkFlagRequired("event")
}
