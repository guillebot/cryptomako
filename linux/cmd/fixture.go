package cmd

import (
	"fmt"
	"os"

	"github.com/guillebot/cryptomako/linux/internal/vault"
	"github.com/spf13/cobra"
)

var (
	flagFixtureOut   string
	flagFixtureHello string
)

var fixtureCmd = &cobra.Command{
	Use:   "fixture",
	Short: "Create a minimal format-8 SIV_GCM vault (CI / local smoke)",
	Long: `Writes masterkey.cryptomator + vault.cryptomator and a sample hello.txt.
Password comes from CRYPTOMAKO_PASSWORD (or --password-env). Does not invent
new VaultSettings keys.`,
	RunE: func(cmd *cobra.Command, args []string) error {
		if flagFixtureOut == "" {
			return fmt.Errorf("missing --output")
		}
		pass := os.Getenv(flagPasswordEnv)
		if pass == "" {
			return fmt.Errorf("missing env %s", flagPasswordEnv)
		}
		_ = os.Unsetenv(flagPasswordEnv)
		if err := os.RemoveAll(flagFixtureOut); err != nil {
			return err
		}
		s, err := vault.CreateFormat8(flagFixtureOut, pass)
		if err != nil {
			return err
		}
		defer s.Close()
		hello := flagFixtureHello
		if hello == "" {
			hello = "hello cryptomako\n"
		}
		if err := s.PutFile("/hello.txt", []byte(hello)); err != nil {
			return err
		}
		fmt.Fprintf(os.Stderr, "wrote format-8 vault at %s\n", flagFixtureOut)
		return nil
	},
}

func init() {
	fixtureCmd.Flags().StringVar(&flagFixtureOut, "output", "", "Directory for the new vault ciphertext")
	fixtureCmd.Flags().StringVar(&flagFixtureHello, "hello", "", "Optional hello.txt contents (default: hello cryptomako\\n)")
	Root.AddCommand(fixtureCmd)
}
