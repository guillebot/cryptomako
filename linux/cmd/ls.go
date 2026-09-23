package cmd

import (
	"fmt"

	"github.com/guillebot/cryptomako/linux/internal/config"
	"github.com/guillebot/cryptomako/linux/internal/vault"
	"github.com/spf13/cobra"
)

var (
	flagLSPath      string
	flagLSRecursive bool
)

var lsCmd = &cobra.Command{
	Use:   "ls",
	Short: "List cleartext names in an unlocked vault",
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

		entries, err := session.List(flagLSPath, flagLSRecursive)
		if err != nil {
			return err
		}
		for _, e := range entries {
			name := e.Name
			if e.IsDir {
				name += "/"
			}
			fmt.Println(name)
		}
		return nil
	},
}

func init() {
	lsCmd.Flags().StringVar(&flagLSPath, "path", "/", "Cleartext path to list")
	lsCmd.Flags().BoolVarP(&flagLSRecursive, "recursive", "R", false, "Walk directories recursively")
}
