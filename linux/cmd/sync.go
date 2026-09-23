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
	flagSyncPreferences string
	flagSyncState       string
	flagSyncSources     string
)

var syncCmd = &cobra.Command{
	Use:   "sync",
	Short: "Encrypt local cleartext tree(s) into the vault (fail-closed puts)",
	Long: `Walk cleartext source(s) and encrypt each file into the unlocked vault.

With --source: sync that directory to --dest (default "/"). Fingerprint keys use
the source basename as vaultFolder (macOS BackupSource default).

With no --source: if ~/.config/cryptomako/backup-sources.json has entries, sync
each source to cleartext /Backups/{vaultFolderName}/ (macOS Backup Sync
convention), using that vaultFolderName for fingerprints. If the store is empty,
errors with help to add sources or pass --source/--dest.

Path excludes honor macOS BackupSyncExcludes keys (directoryNames / fileNames /
fileExtensions) from ~/.config/cryptomako/backup-sync-excludes.json (or
--excludes). Defaults match the macOS app when the file is absent.

Sync concurrency and optional upload pacing come from app-preferences.json
(same keys as macOS AppPreferences). Proxy password is env-only
CRYPTOMAKO_PROXY_PASSWORD.

Per-file fingerprints (size + contentModification) live in
backup-sync-state.json; unchanged files are skipped. Fingerprints update
only after a successful put (fail-closed).`,
	RunE: func(cmd *cobra.Command, args []string) error {
		targets, err := config.ResolveSyncTargets(flagSyncSource, flagSyncDest, flagSyncSources)
		if err != nil {
			return err
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
		prefs := config.LoadAppPreferences(flagSyncPreferences)
		session, err := vault.Unlock(cfg)
		if err != nil {
			return err
		}
		defer session.Close()

		total := 0
		for _, t := range targets {
			n, err := session.SyncCleartextTree(t.SourcePath, t.DestPrefix, &excludes, &prefs, flagSyncState, t.VaultFolderName)
			if err != nil {
				return fmt.Errorf("sync %s → %s: %w", t.SourcePath, t.DestPrefix, err)
			}
			fmt.Printf("synced %d file(s) from %s into %s\n", n, t.SourcePath, t.DestPrefix)
			total += n
		}
		if len(targets) > 1 {
			fmt.Printf("synced %d file(s) across %d source(s)\n", total, len(targets))
		}
		return nil
	},
}

func init() {
	syncCmd.Flags().StringVar(&flagSyncSource, "source", "", "Local cleartext directory to encrypt (omit to use backup-sources.json)")
	syncCmd.Flags().StringVar(&flagSyncDest, "dest", "/", "Cleartext destination path inside the vault (with --source only)")
	syncCmd.Flags().StringVar(&flagSyncExcludes, "excludes", "", "backup-sync-excludes.json path (default XDG)")
	syncCmd.Flags().StringVar(&flagSyncPreferences, "preferences", "", "app-preferences.json path (default XDG)")
	syncCmd.Flags().StringVar(&flagSyncState, "sync-state", "", "backup-sync-state.json path (default XDG)")
	syncCmd.Flags().StringVar(&flagSyncSources, "sources", "", "backup-sources.json path (default XDG)")
	Root.AddCommand(syncCmd)
}
