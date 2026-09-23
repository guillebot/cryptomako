package cmd

import (
	"fmt"
	"os"

	"github.com/spf13/cobra"
)

// Root is the cryptomako CLI entry.
var Root = &cobra.Command{
	Use:   "cryptomako",
	Short: "Unlock and browse Cryptomator format-8 vaults on S3",
	Long: `CryptoMako Linux CLI: point at an S3-compatible bucket (HTTPS / SigV4),
unlock a Cryptomator format-8 vault, and work with cleartext names locally.
Ciphertext never leaves the object store unencrypted; remote put/delete fail closed.`,
	SilenceUsage:  true,
	SilenceErrors: true,
}

// Shared connection flags (non-secrets). Secrets come from env only.
var (
	flagEndpoint  string
	flagRegion    string
	flagBucket    string
	flagPrefix    string
	flagAccessKey string
	flagConfig    string
	flagLocal     string
	flagPasswordEnv  string
	flagSecretKeyEnv string
)

func init() {
	pf := Root.PersistentFlags()
	pf.StringVar(&flagEndpoint, "endpoint", "", "S3 API URL (no bucket in path; HTTPS)")
	pf.StringVar(&flagRegion, "region", "", "AWS region (MinIO: us-east-1)")
	pf.StringVar(&flagBucket, "bucket", "", "Bucket name")
	pf.StringVar(&flagPrefix, "prefix", "", "Vault prefix inside the bucket")
	pf.StringVar(&flagAccessKey, "access-key", "", "Access key id")
	pf.StringVar(&flagConfig, "config", "", "JSON config path (default XDG ~/.config/cryptomako/config.json)")
	pf.StringVar(&flagLocal, "local", "", "Unlock a vault directory on disk instead of S3")
	pf.StringVar(&flagPasswordEnv, "password-env", "CRYPTOMAKO_PASSWORD", "Env var holding the vault password")
	pf.StringVar(&flagSecretKeyEnv, "secret-key-env", "CRYPTOMAKO_SECRET_KEY", "Env var holding the S3 secret key")

	Root.AddCommand(unlockCmd, lsCmd, catCmd)
}

// Execute runs the root command.
func Execute() error {
	if err := Root.Execute(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return err
	}
	return nil
}
