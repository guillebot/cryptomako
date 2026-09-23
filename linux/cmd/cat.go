package cmd

import (
	"io"
	"os"

	"github.com/guillebot/cryptomako/linux/internal/config"
	"github.com/guillebot/cryptomako/linux/internal/vault"
	"github.com/spf13/cobra"
)

var catCmd = &cobra.Command{
	Use:   "cat <cleartext-path>",
	Short: "Decrypt a vault file and write plaintext to stdout",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		cfg, err := config.Resolve(config.Request{
			LocalPath:    flagLocal,
			ConfigPath:   flagConfig,
			Endpoint:     flagEndpoint,
			Region:       flagRegion,
			Bucket:       flagBucket,
			Prefix:       flagPrefix,
			AccessKey:    flagAccessKey,
			PasswordEnv:  flagPasswordEnv,
			SecretKeyEnv: flagSecretKeyEnv,
		})
		if err != nil {
			return err
		}

		session, err := vault.Unlock(cfg)
		if err != nil {
			return err
		}
		defer session.Close()

		r, err := session.Open(args[0])
		if err != nil {
			return err
		}
		defer r.Close()

		_, err = io.Copy(os.Stdout, r)
		return err
	},
}
