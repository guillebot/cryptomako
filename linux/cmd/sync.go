package cmd

import (
	"fmt"

	"github.com/guillebot/cryptomako/linux/internal/config"
	"github.com/guillebot/cryptomako/linux/internal/vault"
	"github.com/spf13/cobra"
)

var (
	flagSyncSource      string
	flagSyncDest        string
	flagSyncExcludes    string
)

var syncCmd = &cobra.Command{
	Use:   "sync",
	Short: "Encrypt a local cleartext tree into the vault (fail-closed puts)",
	Long: `Walk --source and encrypt each file into the unlocked vault under --dest.
Directory markers and ciphertext are written via store.Put; S3 puts fail closed
on non-2xx. Existing cleartext names are overwritten.

Path excludes honor macOS BackupSyncExcludes keys (directoryNames / fileNames /
fileExtensions) from ~/.config/cryptomako/backup-sync-excludes.json (or
--excludes). Defaults match the macOS app when the file is absent.`,
	RunE: func(cmd *cobra.Command, args []string) error {
		if flagSyncSource == "" {
			return fmt.Errorf("missing --source")
		}
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
		excludes, err := config.LoadBackupSyncExcludes(flagSyncExcludes)
		if err != nil {
			return err
		}
		session, err := vault.Unlock(cfg)
		if err != nil {
			return err
		}
		defer session.Close()

		n, err := session.SyncCleartextTree(flagSyncSource, flagSyncDest, &excludes)
		if err != nil {
			return err
		}
		fmt.Printf("synced %d file(s) into %s\n", n, flagSyncDest)
		return nil
	},
}

func init() {
	syncCmd.Flags().StringVar(&flagSyncSource, "source", "", "Local cleartext directory to encrypt")
	syncCmd.Flags().StringVar(&flagSyncDest, "dest", "/", "Cleartext destination path inside the vault")
	syncCmd.Flags().StringVar(&flagSyncExcludes, "excludes", "", "backup-sync-excludes.json path (default XDG)")
	Root.AddCommand(syncCmd)
}
