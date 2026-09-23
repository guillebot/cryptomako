package config

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// OverlapPair is one nested/identical pair of backup sources after path resolve.
type OverlapPair struct {
	A         BackupSource
	B         BackupSource
	ResolvedA string
	ResolvedB string
}

// ResolvePath returns a comparable absolute path (Abs + EvalSymlinks when possible).
// Mirrors Windows BackupPathOverlap.Resolve (GetFullPath + ResolveLinkTarget).
func ResolvePath(path string) (string, error) {
	path = strings.TrimSpace(path)
	if path == "" {
		return "", fmt.Errorf("path required")
	}
	abs, err := filepath.Abs(path)
	if err != nil {
		return "", err
	}
	if resolved, err := filepath.EvalSymlinks(abs); err == nil {
		abs = resolved
	}
	return trimPathSep(abs), nil
}

// IsSameOrPrefix reports whether ancestor and descendant are the same path, or
// ancestor is a directory prefix of descendant. Linux paths are case-sensitive
// (Windows BackupPathOverlap uses Ordinal on Linux).
func IsSameOrPrefix(ancestor, descendant string) bool {
	a := trimPathSep(ancestor)
	b := trimPathSep(descendant)
	if a == b {
		return true
	}
	prefix := a + string(os.PathSeparator)
	return strings.HasPrefix(b, prefix)
}

// FindOverlaps returns every pair whose resolved paths nest or match.
// Unresolvable paths are skipped (soft paths); Sync may still fail later on missing folders.
func FindOverlaps(sources []BackupSource) []OverlapPair {
	type item struct {
		src  BackupSource
		path string
	}
	resolved := make([]item, 0, len(sources))
	for _, s := range sources {
		if strings.TrimSpace(s.Path) == "" {
			continue
		}
		p, err := ResolvePath(s.Path)
		if err != nil {
			continue
		}
		resolved = append(resolved, item{src: s, path: p})
	}

	var pairs []OverlapPair
	for i := 0; i < len(resolved); i++ {
		for j := i + 1; j < len(resolved); j++ {
			pa, pb := resolved[i].path, resolved[j].path
			if IsSameOrPrefix(pa, pb) || IsSameOrPrefix(pb, pa) {
				pairs = append(pairs, OverlapPair{
					A:         resolved[i].src,
					B:         resolved[j].src,
					ResolvedA: pa,
					ResolvedB: pb,
				})
			}
		}
	}
	return pairs
}

// SoftWarnOnAdd returns a human warning when candidatePath would nest under (or
// over) an existing source. Empty string means no overlap. Add is still allowed.
func SoftWarnOnAdd(existing []BackupSource, candidatePath string) string {
	candidate := NewBackupSource(candidatePath, "")
	if abs, err := ResolvePath(candidatePath); err == nil {
		candidate.Path = abs
	}
	overlaps := FindOverlaps(append(append([]BackupSource{}, existing...), candidate))
	if len(overlaps) == 0 {
		return ""
	}
	o := overlaps[0]
	return fmt.Sprintf(
		"Warning: backup source overlaps another (nested paths). '%s' ↔ '%s'. Sync will refuse to start until resolved.",
		o.ResolvedA, o.ResolvedB,
	)
}

// ThrowIfOverlapping hard-fails before Sync when any pair overlaps.
func ThrowIfOverlapping(sources []BackupSource) error {
	overlaps := FindOverlaps(sources)
	if len(overlaps) == 0 {
		return nil
	}
	o := overlaps[0]
	return fmt.Errorf(
		"Backup Sync refused: nested/overlapping sources. '%s' overlaps '%s'. Remove or change one source before syncing.",
		o.ResolvedA, o.ResolvedB,
	)
}

func trimPathSep(p string) string {
	if p == "" {
		return p
	}
	// Keep root "/" intact; trim trailing separators otherwise.
	for len(p) > 1 && (p[len(p)-1] == '/' || p[len(p)-1] == os.PathSeparator) {
		p = p[:len(p)-1]
	}
	return p
}
