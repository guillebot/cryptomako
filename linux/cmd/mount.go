package cmd

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"github.com/guillebot/cryptomako/linux/internal/config"
	"github.com/guillebot/cryptomako/linux/internal/fusefs"
	"github.com/guillebot/cryptomako/linux/internal/vault"
	"github.com/spf13/cobra"
)

var (
	flagMountPoint string
	flagAllowOther bool
	flagMountRW    bool
)

var mountCmd = &cobra.Command{
	Use:   "mount",
	Short: "Mount a vault as a cleartext FUSE filesystem",
	Long: `Mount unlocks the vault and exposes cleartext names/contents via FUSE.
Ciphertext never appears in the mount.

Default is read-only (--ro implied). Pass --rw for create/write/rename/unlink/mkdir;
each mutating op encrypts and PutObject/DeleteObject on the store and fails closed
if the remote op fails (no silent local-only success).

Requires Linux with /dev/fuse (libfuse userspace). Ctrl-C unmounts.`,
	RunE: func(cmd *cobra.Command, args []string) error {
		if flagMountPoint == "" {
			return fmt.Errorf("missing --mountpoint")
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
		session, err := vault.Unlock(cfg)
		if err != nil {
			return err
		}
		defer session.Close()

		ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
		defer stop()

		mode := "ro"
		if flagMountRW {
			mode = "rw"
		}
		fmt.Fprintf(os.Stderr, "mounting format-%d %s at %s (%s)\n", session.Format, session.CipherCombo, flagMountPoint, mode)
		return fusefs.Mount(ctx, flagMountPoint, session, fusefs.Options{
			AllowOther: flagAllowOther,
			ReadWrite:  flagMountRW,
		})
	},
}

func init() {
	mountCmd.Flags().StringVar(&flagMountPoint, "mountpoint", "", "Directory to mount onto (must exist, empty)")
	mountCmd.Flags().BoolVar(&flagAllowOther, "allow-other", false, "Allow other users (needs fuse.conf user_allow_other)")
	mountCmd.Flags().BoolVar(&flagMountRW, "rw", false, "Writable mount (fail-closed remote put/delete)")
	Root.AddCommand(mountCmd)
}
