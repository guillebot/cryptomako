package config

import (
	"fmt"
	"path/filepath"
	"strings"
)

// RelativeUnderRoot returns the slash-separated relative path of absPath under
// rootAbs. Fail-closed: rejects paths outside the root (no basename fallback).
// Mirrors Sources/CryptoMakoShared/BackupRelativePath.swift.
func RelativeUnderRoot(absPath, rootAbs string) (string, error) {
	absPath = filepath.Clean(absPath)
	rootAbs = filepath.Clean(rootAbs)
	if absPath == rootAbs {
		return "", nil
	}
	rel, err := filepath.Rel(rootAbs, absPath)
	if err != nil {
		return "", fmt.Errorf("path is not under backup source root: %s (root %s)", absPath, rootAbs)
	}
	rel = filepath.ToSlash(rel)
	if rel == ".." || strings.HasPrefix(rel, "../") {
		return "", fmt.Errorf("path is not under backup source root: %s (root %s)", absPath, rootAbs)
	}
	return rel, nil
}
