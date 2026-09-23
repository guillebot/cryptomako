package cmd

import (
	"fmt"
	"runtime"

	"github.com/spf13/cobra"
)

// Version metadata — override at link time, e.g.:
//
//	go build -ldflags "-X github.com/guillebot/cryptomako/linux/cmd.Version=1.0.0 -X github.com/guillebot/cryptomako/linux/cmd.GitCommit=$(git rev-parse --short HEAD)"
var (
	Version   = "1.0.0"
	GitCommit = "unknown"
)

func versionString() string {
	return fmt.Sprintf("cryptomako %s (commit %s, %s/%s)", Version, GitCommit, runtime.GOOS, runtime.GOARCH)
}

var versionCmd = &cobra.Command{
	Use:   "version",
	Short: "Print CryptoMako Linux version",
	Run: func(cmd *cobra.Command, args []string) {
		fmt.Println(versionString())
	},
}

func init() {
	Root.Version = versionString()
	Root.SetVersionTemplate("{{.Version}}\n")
	Root.AddCommand(versionCmd)
}
