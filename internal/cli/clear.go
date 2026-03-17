package cli

import (
	"fmt"
	"os"

	"github.com/joshheyse/kgd/internal/kitty"
	"github.com/spf13/cobra"
)

var clearCmd = &cobra.Command{
	Use:   "clear",
	Short: "Delete all kitty graphics images from the terminal",
	Long:  "Sends the kitty graphics 'delete all' command directly to the terminal. Works without the daemon running. Handles tmux DCS wrapping automatically.",
	RunE: func(cmd *cobra.Command, args []string) error {
		seq := kitty.DeleteCommand{Free: true}.SerializeDeleteAll()
		if os.Getenv("TMUX") != "" {
			seq = kitty.WrapTmux(seq)
		}
		_, err := fmt.Fprint(os.Stdout, seq)
		return err
	},
}
