package vault

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/google/uuid"
)

// PutFile encrypts cleartext bytes and stores them under cleartextPath (absolute).
// Creates parent directories as needed. Fail-closed on store.Put errors.
func (s *Session) PutFile(cleartextPath string, clear []byte) error {
	parts := splitPath(cleartextPath)
	if len(parts) == 0 {
		return fmt.Errorf("vault: invalid path %q", cleartextPath)
	}
	parentID, err := s.ensureDirPath(parts[:len(parts)-1])
	if err != nil {
		return err
	}
	name := parts[len(parts)-1]
	return s.putFileInDir(parentID, name, clear)
}

// EnsureDir creates cleartextPath as a directory (mkdir -p semantics).
func (s *Session) EnsureDir(cleartextPath string) error {
	parts := splitPath(cleartextPath)
	_, err := s.ensureDirPath(parts)
	return err
}

func (s *Session) ensureDirPath(parts []string) (string, error) {
	dirID := ""
	for _, part := range parts {
		nodes, err := s.listDir(dirID)
		if err != nil {
			return "", err
		}
		found := false
		for _, n := range nodes {
			if n.clearName == part && n.kind == nodeDir && n.dirID != "" {
				dirID = n.dirID
				found = true
				break
			}
		}
		if found {
			continue
		}
		childID, err := s.createDirectory(dirID, part)
		if err != nil {
			return "", err
		}
		dirID = childID
	}
	return dirID, nil
}

func (s *Session) createDirectory(parentDirID, name string) (string, error) {
	encName, err := s.cryptor.EncryptFileName(name, parentDirID)
	if err != nil {
		return "", err
	}
	parentPrefix, err := s.cryptor.dirPrefix(parentDirID)
	if err != nil {
		return "", err
	}
	display := encName
	shortened := len(encName) > s.shorteningThresh
	if shortened {
		display = ShortenedName(encName)
	}
	folder := parentPrefix + display + "/"
	childDirID := uuid.NewString()
	idData := []byte(childDirID)

	if shortened {
		if err := s.store.Put(folder+"name.c9s", []byte(encName)); err != nil {
			return "", err
		}
	}
	if err := s.store.Put(folder+"dir.c9r", idData); err != nil {
		return "", err
	}
	childPrefix, err := s.cryptor.dirPrefix(childDirID)
	if err != nil {
		return "", err
	}
	// Match macOS CryptoMako: plaintext dir ID in dirid.c9r (recoverability aid).
	if err := s.store.Put(childPrefix+"dirid.c9r", idData); err != nil {
		return "", err
	}
	return childDirID, nil
}

func (s *Session) putFileInDir(parentDirID, name string, clear []byte) error {
	encName, err := s.cryptor.EncryptFileName(name, parentDirID)
	if err != nil {
		return err
	}
	parentPrefix, err := s.cryptor.dirPrefix(parentDirID)
	if err != nil {
		return err
	}
	ct, err := s.cryptor.EncryptContent(clear)
	if err != nil {
		return err
	}
	shortened := len(encName) > s.shorteningThresh
	if shortened {
		display := ShortenedName(encName)
		folder := parentPrefix + display + "/"
		if err := s.store.Put(folder+"name.c9s", []byte(encName)); err != nil {
			return err
		}
		return s.store.Put(folder+"contents.c9r", ct)
	}
	return s.store.Put(parentPrefix+encName, ct)
}

// SyncCleartextTree walks localRoot and encrypts every file into the vault
// under destPrefix (absolute cleartext path, default "/").
func (s *Session) SyncCleartextTree(localRoot, destPrefix string) (files int, err error) {
	destPrefix = normalizePath(destPrefix)
	localRoot, err = filepath.Abs(localRoot)
	if err != nil {
		return 0, err
	}
	err = filepath.WalkDir(localRoot, func(path string, d os.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		rel, err := filepath.Rel(localRoot, path)
		if err != nil {
			return err
		}
		if rel == "." {
			return nil
		}
		rel = filepath.ToSlash(rel)
		clearPath := destPrefix
		if clearPath == "/" {
			clearPath = "/" + rel
		} else {
			clearPath = strings.TrimSuffix(clearPath, "/") + "/" + rel
		}
		if d.IsDir() {
			return s.EnsureDir(clearPath)
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		if err := s.PutFile(clearPath, data); err != nil {
			return err
		}
		files++
		return nil
	})
	return files, err
}
