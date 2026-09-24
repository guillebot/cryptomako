package cmd

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"strings"
	"syscall"

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
	flagSyncMode        string
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

Transfer mode (prefs key backupTransferMode, default backup; override with --mode):
  - backup: put/update only. Never deletes local source. Never deletes vault extras.
  - sync: same puts, then delete vault ciphertext orphans under that source's
    dest folder only (macOS Backups/<folder>/). Never deletes local source.
    Refuses dest "/". Remote deletes fail closed.

Sync concurrency and optional upload pacing come from app-preferences.json
(same keys as macOS AppPreferences). Proxy password is env-only
CRYPTOMAKO_PROXY_PASSWORD.

Per-file fingerprints (size + contentModification) live in
backup-sync-state.json; unchanged files are skipped. Fingerprints update
only after a successful put (fail-closed).

Nested/overlapping sources (one resolved path prefixes another) soft-warn on
"sources add" and hard-fail here before any unlock or remote put (Windows #12
parity). No new shared settings keys.

Ctrl-C / SIGTERM cancels in-flight sync (stops scheduling new puts; workers
finish or exit; process returns a cancelled error). Session is closed on exit;
OS secret store is untouched.`,
	RunE: func(cmd *cobra.Command, args []string) error {
		targets, err := config.ResolveSyncTargets(flagSyncSource, flagSyncDest, flagSyncSources)
		if err != nil {
			return err
		}
		// Platforms consensus (Windows #12): hard-fail nested overlaps before unlock/puts
		// when syncing from backup-sources.json (omit --source).
		if strings.TrimSpace(flagSyncSource) == "" {
			store := config.LoadBackupSources(flagSyncSources)
			if err := config.ThrowIfOverlapping(store.Sources); err != nil {
				return err
			}
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
		if strings.TrimSpace(flagSyncMode) != "" {
			m := strings.ToLower(strings.TrimSpace(flagSyncMode))
			if m != config.BackupTransferModeBackup && m != config.BackupTransferModeSync {
				return fmt.Errorf("invalid --mode %q (want backup|sync)", flagSyncMode)
			}
			prefs.BackupTransferMode = m
		}
		session, err := vault.Unlock(cfg)
		if err != nil {
			return err
		}
		defer session.Close()

		ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
		defer stop()

		total := 0
		totalDeleted := 0
		for _, t := range targets {
			n, deleted, err := session.SyncCleartextTree(ctx, t.SourcePath, t.DestPrefix, &excludes, &prefs, flagSyncState, t.VaultFolderName)
			if err != nil {
				return fmt.Errorf("sync %s → %s: %w", t.SourcePath, t.DestPrefix, err)
			}
			verb := "backed up"
			if prefs.IsSyncTransferMode() {
				verb = "synced"
			}
			if deleted > 0 {
				fmt.Printf("%s %d file(s) from %s into %s (removed %d vault-only)\n", verb, n, t.SourcePath, t.DestPrefix, deleted)
			} else {
				fmt.Printf("%s %d file(s) from %s into %s\n", verb, n, t.SourcePath, t.DestPrefix)
			}
			total += n
			totalDeleted += deleted
		}
		if len(targets) > 1 {
			verb := "backed up"
			if prefs.IsSyncTransferMode() {
				verb = "synced"
			}
			if totalDeleted > 0 {
				fmt.Printf("%s %d file(s) across %d source(s) (removed %d vault-only)\n", verb, total, len(targets), totalDeleted)
			} else {
				fmt.Printf("%s %d file(s) across %d source(s)\n", verb, total, len(targets))
			}
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
	syncCmd.Flags().StringVar(&flagSyncMode, "mode", "", "transfer mode backup|sync (default: prefs backupTransferMode, else backup)")
	Root.AddCommand(syncCmd)
}
