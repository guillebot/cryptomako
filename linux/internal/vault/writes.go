package vault

import (
	"fmt"
	"io"
	"os"
	"path"
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

// DeleteFile removes a cleartext file's ciphertext from the store. Fail-closed.
func (s *Session) DeleteFile(cleartextPath string) error {
	n, err := s.resolve(cleartextPath)
	if err != nil {
		return err
	}
	if n.kind != nodeFile {
		return fmt.Errorf("%w: %s", errNotAFile, cleartextPath)
	}
	if strings.HasSuffix(n.cipherName, ".c9s") {
		folder := strings.TrimSuffix(n.ciphertextKey, "contents.c9r")
		_ = s.store.Delete(folder + "name.c9s") // best-effort companion
		if err := s.store.Delete(n.ciphertextKey); err != nil {
			return err
		}
		return nil
	}
	return s.store.Delete(n.ciphertextKey)
}

// DeletePath removes a file or directory (directories recursively). Fail-closed
// on required remote deletes.
func (s *Session) DeletePath(cleartextPath string) error {
	n, err := s.resolve(cleartextPath)
	if err != nil {
		return err
	}
	switch n.kind {
	case nodeFile, nodeSymlink:
		return s.DeleteFile(cleartextPath)
	case nodeDir:
		return s.deleteDirectory(n, true)
	default:
		return fmt.Errorf("vault: cannot delete %s", cleartextPath)
	}
}

func (s *Session) deleteDirectory(n node, recursive bool) error {
	if n.kind != nodeDir || n.dirID == "" {
		return fmt.Errorf("vault: not a directory")
	}
	children, err := s.listDir(n.dirID)
	if err != nil {
		return err
	}
	if len(children) > 0 {
		if !recursive {
			return fmt.Errorf("vault: directory not empty")
		}
		for _, ch := range children {
			switch ch.kind {
			case nodeDir:
				if err := s.deleteDirectory(ch, true); err != nil {
					return err
				}
			default:
				if strings.HasSuffix(ch.cipherName, ".c9s") {
					folder := strings.TrimSuffix(ch.ciphertextKey, "contents.c9r")
					if ch.kind == nodeSymlink {
						folder = strings.TrimSuffix(ch.ciphertextKey, "symlink.c9r")
					}
					_ = s.store.Delete(folder + "name.c9s")
				}
				if err := s.store.Delete(ch.ciphertextKey); err != nil {
					return err
				}
			}
		}
	}
	// Parent dir marker
	if n.ciphertextKey != "" {
		if err := s.store.Delete(n.ciphertextKey); err != nil {
			return err
		}
		if strings.HasSuffix(n.cipherName, ".c9s") {
			folder := strings.TrimSuffix(n.ciphertextKey, "dir.c9r")
			_ = s.store.Delete(folder + "name.c9s")
		}
	}
	childPrefix, err := s.cryptor.dirPrefix(n.dirID)
	if err != nil {
		return err
	}
	_ = s.store.Delete(childPrefix + "dirid.c9r")
	return nil
}

// Rename moves a cleartext file or directory. Fail-closed: destination put must
// succeed before source delete; a failed delete surfaces as an error (no silent success).
func (s *Session) Rename(oldPath, newPath string) error {
	oldPath = normalizePath(oldPath)
	newPath = normalizePath(newPath)
	if oldPath == "/" || newPath == "/" {
		return fmt.Errorf("vault: cannot rename root")
	}
	if oldPath == newPath {
		return nil
	}
	if _, err := s.resolve(newPath); err == nil {
		return fmt.Errorf("vault: already exists: %s", newPath)
	}
	n, err := s.resolve(oldPath)
	if err != nil {
		return err
	}
	switch n.kind {
	case nodeFile:
		r, err := s.Open(oldPath)
		if err != nil {
			return err
		}
		data, err := io.ReadAll(r)
		r.Close()
		if err != nil {
			return err
		}
		if err := s.PutFile(newPath, data); err != nil {
			return err
		}
		return s.DeleteFile(oldPath)
	case nodeDir:
		if err := s.EnsureDir(newPath); err != nil {
			return err
		}
		children, err := s.List(oldPath, false)
		if err != nil {
			return err
		}
		for _, e := range children {
			base := path.Base(e.Name)
			if err := s.Rename(e.Name, joinClear(newPath, base)); err != nil {
				return err
			}
		}
		n2, err := s.resolve(oldPath)
		if err != nil {
			return err
		}
		return s.deleteDirectory(n2, false)
	default:
		return fmt.Errorf("vault: cannot rename %s", oldPath)
	}
}
