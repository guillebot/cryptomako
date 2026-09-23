// CryptoMako Linux CLI — Cryptomator format-8 vaults on S3-compatible storage.
package main

import (
	"os"

	"github.com/guillebot/cryptomako/linux/cmd"
)

func main() {
	if err := cmd.Execute(); err != nil {
		os.Exit(1)
	}
}
