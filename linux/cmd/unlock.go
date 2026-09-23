package cmd

import (
	"fmt"

	"github.com/guillebot/cryptomako/linux/internal/config"
	"github.com/guillebot/cryptomako/linux/internal/vault"
	"github.com/spf13/cobra"
)

var unlockCmd = &cobra.Command{
	Use:   "unlock",
	Short: "Unlock a Cryptomator format-8 vault (local or S3)",
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

		fmt.Printf("format: %d\n", session.Format)
		fmt.Printf("cipherCombo: %s\n", session.CipherCombo)
		fmt.Printf("rootPrefix: %s\n", session.RootCipherPrefix)
		return nil
	},
}
