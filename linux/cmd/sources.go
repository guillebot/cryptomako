package cmd

import (
	"fmt"
	"os"
	"text/tabwriter"
	"time"

	"github.com/guillebot/cryptomako/linux/internal/config"
	"github.com/spf13/cobra"
)

var flagSourcesFile string

var sourcesCmd = &cobra.Command{
	Use:   "sources",
	Short: "Manage backup-sources.json (folders synced into Backups/)",
	Long: `Thin management for ~/.config/cryptomako/backup-sources.json — the same
schema as macOS BackupSourcesStore (id, path, vaultFolderName, addedAt).

When backup-sources.json has entries, cryptomako sync (without --source) syncs
each folder to cleartext /Backups/{vaultFolderName}/.`,
}

var sourcesListCmd = &cobra.Command{
	Use:   "list",
	Short: "List configured backup sources",
	RunE: func(cmd *cobra.Command, args []string) error {
		store := config.LoadBackupSources(flagSourcesFile)
		if len(store.Sources) == 0 {
			fmt.Println("(no backup sources — add with: cryptomako sources add PATH)")
			return nil
		}
		w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
		fmt.Fprintln(w, "ID\tVAULT_FOLDER\tPATH\tADDED")
		for _, s := range store.Sources {
			added := appleRefToRFC3339(s.AddedAt)
			fmt.Fprintf(w, "%s\t%s\t%s\t%s\n", s.ID, s.VaultFolderName, s.Path, added)
		}
		return w.Flush()
	},
}

var sourcesAddCmd = &cobra.Command{
	Use:   "add PATH",
	Short: "Add a local folder as a backup source",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		vaultFolder, _ := cmd.Flags().GetString("vault-folder")
		store := config.LoadBackupSources(flagSourcesFile)
		// Platforms consensus (Windows #12): soft-warn on nested/overlapping add; still allow.
		if warn := config.SoftWarnOnAdd(store.Sources, args[0]); warn != "" {
			fmt.Fprintln(os.Stderr, warn)
		}
		src, added, err := store.Add(args[0], vaultFolder)
		if err != nil {
			return err
		}
		if !added {
			fmt.Printf("already listed: %s → Backups/%s/\n", src.Path, src.VaultFolderName)
			return nil
		}
		if err := store.Save(flagSourcesFile); err != nil {
			return err
		}
		fmt.Printf("added %s → Backups/%s/ (id %s)\n", src.Path, src.VaultFolderName, src.ID)
		return nil
	},
}

var sourcesRemoveCmd = &cobra.Command{
	Use:   "remove ID|PATH",
	Short: "Remove a backup source by id or path",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		store := config.LoadBackupSources(flagSourcesFile)
		if !store.Remove(args[0]) {
			return fmt.Errorf("no backup source matching %q", args[0])
		}
		if err := store.Save(flagSourcesFile); err != nil {
			return err
		}
		fmt.Printf("removed %s\n", args[0])
		return nil
	},
}

func appleRefToRFC3339(addedAt float64) string {
	// addedAt is seconds since 2001-01-01 UTC (Apple reference date).
	sec := int64(addedAt)
	nsec := int64((addedAt - float64(sec)) * 1e9)
	t := time.Unix(config.AppleReferenceDateUnix+sec, nsec).UTC()
	return t.Format(time.RFC3339)
}

func init() {
	sourcesCmd.PersistentFlags().StringVar(&flagSourcesFile, "file", "", "backup-sources.json path (default XDG)")
	sourcesAddCmd.Flags().String("vault-folder", "", "Cleartext folder name under Backups/ (default: basename of PATH)")
	sourcesCmd.AddCommand(sourcesListCmd, sourcesAddCmd, sourcesRemoveCmd)
	Root.AddCommand(sourcesCmd)
}
