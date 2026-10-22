package config

import (
	"path/filepath"
	"testing"
)

func TestRelativeUnderRootNested(t *testing.T) {
	root := filepath.Join(string(filepath.Separator), "tmp", "src")
	file := filepath.Join(root, "a", "b.txt")
	rel, err := RelativeUnderRoot(file, root)
	if err != nil {
		t.Fatal(err)
	}
	if rel != "a/b.txt" {
		t.Fatalf("got %q", rel)
	}
}

func TestRelativeUnderRootRejectsOutside(t *testing.T) {
	root := filepath.Join(string(filepath.Separator), "tmp", "src")
	outside := filepath.Join(string(filepath.Separator), "tmp", "other", "x.txt")
	if _, err := RelativeUnderRoot(outside, root); err == nil {
		t.Fatal("expected error for path outside root")
	}
}

func TestRelativeUnderRootRejectsSiblingPrefix(t *testing.T) {
	root := filepath.Join(string(filepath.Separator), "tmp", "src")
	// String-prefix trap: /tmp/src-evil is not under /tmp/src
	sibling := filepath.Join(string(filepath.Separator), "tmp", "src-evil", "x.txt")
	if _, err := RelativeUnderRoot(sibling, root); err == nil {
		t.Fatal("expected error for sibling prefix path")
	}
}
