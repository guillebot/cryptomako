package vault

import (
	"context"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/guillebot/cryptomako/linux/internal/config"
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

// Size tiers match macOS / Windows BackupSyncEngine (cleartext bytes).
const (
	MediumFileBytes = 256 * 1024
	LargeFileBytes  = 32 * 1024 * 1024
)

type pendingUpload struct {
	absPath   string
	clearPath string
	relPath   string
	size      int64
	mtime     time.Time
}

// SyncCleartextTree walks localRoot and encrypts every file into the vault
// under destPrefix (absolute cleartext path, default "/").
// Excludes honor macOS BackupSyncExcludes (directoryNames / fileNames / fileExtensions).
// Pass a zero value or DefaultBackupSyncExcludes(); nil pointer uses defaults.
// prefs nil → DefaultAppPreferences (size-tiered concurrency + optional bandwidth pacing).
//
// Fingerprints (mtime + size) come from BackupSyncState (macOS BackupSyncState.swift).
// Unchanged files are skipped; fingerprints update only after a successful put
// (fail-closed). statePath empty → ~/.config/cryptomako/backup-sync-state.json.
// Index save is best-effort and never fails the sync.
// vaultFolderName empty → basename of localRoot (macOS BackupSource default);
// multi-source sync passes BackupSource.vaultFolderName explicitly.
func (s *Session) SyncCleartextTree(localRoot, destPrefix string, excludes *config.BackupSyncExcludes, prefs *config.AppPreferences, statePath, vaultFolderName string) (files int, err error) {
	ex := config.DefaultBackupSyncExcludes()
	if excludes != nil {
		ex = *excludes
	}
	p := config.DefaultAppPreferences()
	if prefs != nil {
		p = *prefs
	}
	p.ClampSyncWorkers()

	destPrefix = normalizePath(destPrefix)
	localRoot, err = filepath.Abs(localRoot)
	if err != nil {
		return 0, err
	}
	vaultFolder := strings.TrimSpace(vaultFolderName)
	if vaultFolder == "" {
		vaultFolder = config.VaultFolderNameForSource(localRoot)
	}
	state := config.LoadBackupSyncState(statePath)
	var stateMu sync.Mutex
	defer func() {
		stateMu.Lock()
		state.Save(statePath)
		stateMu.Unlock()
	}()

	var (
		jobs      []pendingUpload
		sinceSave int
	)
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
		base := filepath.Base(path)
		if d.IsDir() {
			if ex.ShouldSkipDirectory(base) {
				return filepath.SkipDir
			}
		} else {
			if ex.ShouldSkipFile(base) || ex.ShouldSkipRelativePath(rel) {
				return nil
			}
		}
		clearPath := destPrefix
		if clearPath == "/" {
			clearPath = "/" + rel
		} else {
			clearPath = strings.TrimSuffix(clearPath, "/") + "/" + rel
		}
		if d.IsDir() {
			return s.EnsureDir(clearPath)
		}
		info, err := d.Info()
		if err != nil {
			return err
		}
		mtime := info.ModTime()
		size := info.Size()
		stateKey := config.BackupSyncStateKey(vaultFolder, rel)
		if fp, ok := state.Get(stateKey); ok && fp.Matches(size, mtime) {
			sinceSave++
			if sinceSave >= 500 {
				state.Save(statePath)
				sinceSave = 0
			}
			return nil
		}
		jobs = append(jobs, pendingUpload{
			absPath:   path,
			clearPath: clearPath,
			relPath:   rel,
			size:      size,
			mtime:     mtime,
		})
		return nil
	})
	if err != nil {
		return 0, err
	}
	if len(jobs) == 0 {
		return 0, nil
	}

	// Ensure destination + unique parents sequentially so parallel PutFile
	// workers do not race createDirectory on the same cleartext folder.
	if destPrefix != "/" {
		if err := s.EnsureDir(destPrefix); err != nil {
			return 0, err
		}
	}
	seenParents := map[string]struct{}{}
	for _, job := range jobs {
		parent := path.Dir(job.clearPath)
		if parent == "/" || parent == "." || parent == "" {
			continue
		}
		if _, ok := seenParents[parent]; ok {
			continue
		}
		seenParents[parent] = struct{}{}
		if err := s.EnsureDir(parent); err != nil {
			return 0, err
		}
	}

	limiter := config.UploadBandwidthLimiterFromPreferences(p)
	smallCh := make(chan pendingUpload, len(jobs))
	mediumCh := make(chan pendingUpload, len(jobs))
	largeCh := make(chan pendingUpload, len(jobs))

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	var (
		mu       sync.Mutex
		uploaded int
		firstErr error
	)
	setErr := func(e error) {
		if e == nil {
			return
		}
		mu.Lock()
		if firstErr == nil {
			firstErr = e
			cancel()
		}
		mu.Unlock()
	}

	worker := func(ch <-chan pendingUpload) {
		for job := range ch {
			if ctx.Err() != nil {
				continue
			}
			if limiter != nil {
				limiter.Acquire(job.size)
			}
			data, err := os.ReadFile(job.absPath)
			if err != nil {
				setErr(err)
				continue
			}
			if err := s.PutFile(job.clearPath, data); err != nil {
				setErr(err)
				continue
			}
			key := config.BackupSyncStateKey(vaultFolder, job.relPath)
			fp := config.NewBackupFileFingerprint(job.size, job.mtime)
			stateMu.Lock()
			state.Set(key, fp)
			stateMu.Unlock()
			mu.Lock()
			uploaded++
			mu.Unlock()
		}
	}

	var wg sync.WaitGroup
	start := func(n int, ch <-chan pendingUpload) {
		for i := 0; i < n; i++ {
			wg.Add(1)
			go func() {
				defer wg.Done()
				worker(ch)
			}()
		}
	}
	start(p.ClampedSmallPutConcurrency(), smallCh)
	start(p.ClampedMediumPutConcurrency(), mediumCh)
	start(p.ClampedLargePutConcurrency(), largeCh)

	for _, job := range jobs {
		if ctx.Err() != nil {
			break
		}
		switch {
		case job.size >= LargeFileBytes:
			largeCh <- job
		case job.size >= MediumFileBytes:
			mediumCh <- job
		default:
			smallCh <- job
		}
	}
	close(smallCh)
	close(mediumCh)
	close(largeCh)
	wg.Wait()

	mu.Lock()
	defer mu.Unlock()
	return uploaded, firstErr
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
