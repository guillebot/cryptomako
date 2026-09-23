// Package vault implements Cryptomator format-8 unlock/list/open (SIV_GCM).
package vault

import (
	"bytes"
	"fmt"
	"io"
	"path"
	"sort"
	"strings"

	"github.com/guillebot/cryptomako/linux/internal/config"
	"github.com/guillebot/cryptomako/linux/internal/s3"
)

// Format8 is the locked Cryptomator vault format version for CryptoMako.
const Format8 = 8

const defaultShorteningThreshold = 220

// Entry is a cleartext directory listing row (Name is absolute cleartext path).
type Entry struct {
	Name  string
	IsDir bool
}

type nodeKind int

const (
	nodeFile nodeKind = iota
	nodeDir
	nodeSymlink
)

type node struct {
	clearName     string
	kind          nodeKind
	cipherName    string
	parentDirID   string
	dirID         string
	ciphertextKey string
}

// Session is an unlocked vault handle (cleartext UX; ciphertext stays on store).
type Session struct {
	Format           int
	CipherCombo      string
	RootCipherPrefix string
	shorteningThresh int

	cfg     config.Config
	store   objectStore
	cryptor *Cryptor
}

// Unlock opens a format-8 SIV_GCM vault from local disk or S3 config.
func Unlock(cfg config.Config) (*Session, error) {
	if cfg.Passphrase == "" {
		return nil, fmt.Errorf("vault: missing passphrase")
	}
	if cfg.IsLocal() {
		store, err := newLocalStore(cfg.LocalRoot)
		if err != nil {
			return nil, err
		}
		return unlockWithStore(cfg, store)
	}
	client, err := s3.New(s3.Settings{
		Endpoint:  cfg.Endpoint,
		Region:    cfg.Region,
		Bucket:    cfg.Bucket,
		AccessKey: cfg.AccessKey,
		SecretKey: cfg.SecretKey,
		PathStyle: cfg.PathStyle,
	})
	if err != nil {
		return nil, err
	}
	// AppPreferences proxyMode → HTTP(S) transport (system/direct/custom).
	prefs := config.LoadAppPreferences("")
	client.SetHTTPClient(config.NewHTTPClient(prefs))
	return unlockWithStore(cfg, newS3StoreFrom(client, cfg.Prefix))
}

func unlockWithStore(cfg config.Config, store objectStore) (*Session, error) {
	jwtBytes, err := store.Get("vault.cryptomator")
	if err != nil {
		return nil, fmt.Errorf("vault: read vault.cryptomator: %w", err)
	}
	jwt := strings.TrimSpace(string(jwtBytes))
	if jwt == "" {
		return nil, errUnlockFailed
	}

	_, unverified, _, err := decodeUnverifiedJWT(jwt)
	if err != nil {
		return nil, errUnlockFailed
	}
	if unverified.Format != Format8 {
		return nil, fmt.Errorf("%w: %d", errUnsupportedFormat, unverified.Format)
	}

	mkBytes, err := store.Get("masterkey.cryptomator")
	if err != nil {
		return nil, fmt.Errorf("vault: read masterkey.cryptomator: %w", err)
	}
	mk, err := UnlockMasterkey(bytes.NewReader(mkBytes), cfg.Passphrase)
	if err != nil {
		return nil, errUnlockFailed
	}

	payload, err := verifyVaultJWT(jwt, mk.RawKey())
	if err != nil {
		wipe(mk.EncKey)
		wipe(mk.MacKey)
		return nil, errUnlockFailed
	}
	if payload.Format != Format8 {
		wipe(mk.EncKey)
		wipe(mk.MacKey)
		return nil, fmt.Errorf("%w: %d", errUnsupportedFormat, payload.Format)
	}
	if payload.CipherCombo != "SIV_GCM" {
		wipe(mk.EncKey)
		wipe(mk.MacKey)
		return nil, fmt.Errorf("%w: %s", errUnsupportedCipher, payload.CipherCombo)
	}

	thresh := payload.ShorteningThreshold
	if thresh == 0 {
		thresh = defaultShorteningThreshold
	}
	cryptor := newCryptor(mk)
	rootPrefix, err := cryptor.dirPrefix("")
	if err != nil {
		cryptor.close()
		return nil, errUnlockFailed
	}

	return &Session{
		Format:           payload.Format,
		CipherCombo:      payload.CipherCombo,
		RootCipherPrefix: rootPrefix,
		shorteningThresh: thresh,
		cfg:              cfg,
		store:            store,
		cryptor:          cryptor,
	}, nil
}

// Close wipes key material.
func (s *Session) Close() error {
	if s.cryptor != nil {
		s.cryptor.close()
		s.cryptor = nil
	}
	return nil
}

// List returns cleartext absolute paths under cleartextPath.
func (s *Session) List(cleartextPath string, recursive bool) ([]Entry, error) {
	start := normalizePath(cleartextPath)
	dirID := ""
	if start != "/" {
		n, err := s.resolve(start)
		if err != nil {
			return nil, err
		}
		if n.kind != nodeDir || n.dirID == "" {
			return nil, fmt.Errorf("vault: not a directory: %s", start)
		}
		dirID = n.dirID
	}

	if !recursive {
		nodes, err := s.listDir(dirID)
		if err != nil {
			return nil, err
		}
		out := make([]Entry, 0, len(nodes))
		for _, n := range nodes {
			p := joinClear(start, n.clearName)
			out = append(out, Entry{Name: p, IsDir: n.kind == nodeDir})
		}
		return out, nil
	}

	var out []Entry
	type frame struct {
		dirID string
		path  string
		nodes []node
		idx   int
	}
	rootNodes, err := s.listDir(dirID)
	if err != nil {
		return nil, err
	}
	stack := []frame{{dirID: dirID, path: start, nodes: rootNodes, idx: 0}}
	for len(stack) > 0 {
		top := &stack[len(stack)-1]
		if top.idx >= len(top.nodes) {
			stack = stack[:len(stack)-1]
			continue
		}
		n := top.nodes[top.idx]
		top.idx++
		childPath := joinClear(top.path, n.clearName)
		out = append(out, Entry{Name: childPath, IsDir: n.kind == nodeDir})
		if n.kind == nodeDir && n.dirID != "" {
			childNodes, err := s.listDir(n.dirID)
			if err != nil {
				return nil, err
			}
			stack = append(stack, frame{dirID: n.dirID, path: childPath, nodes: childNodes, idx: 0})
		}
	}
	return out, nil
}

// Open decrypts a cleartext file path.
func (s *Session) Open(cleartextPath string) (io.ReadCloser, error) {
	n, err := s.resolve(cleartextPath)
	if err != nil {
		return nil, err
	}
	if n.kind != nodeFile {
		return nil, fmt.Errorf("%w: %s", errNotAFile, cleartextPath)
	}
	ct, err := s.store.Get(n.ciphertextKey)
	if err != nil {
		return nil, err
	}
	pt, err := s.cryptor.DecryptContent(ct)
	if err != nil {
		return nil, err
	}
	return io.NopCloser(bytes.NewReader(pt)), nil
}

func (s *Session) listDir(dirID string) ([]node, error) {
	prefix, err := s.cryptor.dirPrefix(dirID)
	if err != nil {
		return nil, err
	}
	objects, prefixes, err := s.store.ListImmediate(prefix)
	if err != nil {
		return nil, err
	}
	var nodes []node
	for _, key := range objects {
		name := strings.TrimPrefix(key, prefix)
		if name == "" || strings.Contains(name, "/") {
			continue
		}
		if name == "dirid.c9r" {
			continue
		}
		if strings.HasSuffix(name, ".c9r") {
			if n, ok := s.nodeForFile(name, dirID, key); ok {
				nodes = append(nodes, n)
			}
		}
	}
	for _, pfx := range prefixes {
		folder := strings.TrimSuffix(strings.TrimPrefix(pfx, prefix), "/")
		if folder == "" || strings.Contains(folder, "/") {
			continue
		}
		if n, ok := s.nodeForDirPrefix(folder, dirID, pfx); ok {
			nodes = append(nodes, n)
		}
	}
	sort.Slice(nodes, func(i, j int) bool {
		return strings.ToLower(nodes[i].clearName) < strings.ToLower(nodes[j].clearName)
	})
	return nodes, nil
}

func (s *Session) nodeForFile(name, parentDirID, key string) (node, bool) {
	bare := strings.TrimSuffix(name, ".c9r")
	clear, err := s.cryptor.DecryptFileName(bare, parentDirID)
	if err != nil {
		return node{}, false
	}
	return node{
		clearName:     clear,
		kind:          nodeFile,
		cipherName:    name,
		parentDirID:   parentDirID,
		ciphertextKey: key,
	}, true
}

func (s *Session) nodeForDirPrefix(cipherName, parentDirID, folderPrefix string) (node, bool) {
	if !strings.HasSuffix(folderPrefix, "/") {
		folderPrefix += "/"
	}
	if strings.HasSuffix(cipherName, ".c9s") {
		return s.nodeForShortened(cipherName, parentDirID, folderPrefix)
	}
	if !strings.HasSuffix(cipherName, ".c9r") {
		return node{}, false
	}
	bare := strings.TrimSuffix(cipherName, ".c9r")
	clear, err := s.cryptor.DecryptFileName(bare, parentDirID)
	if err != nil {
		return node{}, false
	}
	if dirBytes, err := s.store.Get(folderPrefix + "dir.c9r"); err == nil {
		childID := strings.TrimSpace(string(dirBytes))
		return node{
			clearName:     clear,
			kind:          nodeDir,
			cipherName:    cipherName,
			parentDirID:   parentDirID,
			dirID:         childID,
			ciphertextKey: folderPrefix + "dir.c9r",
		}, true
	}
	if s.store.Exists(folderPrefix + "symlink.c9r") {
		return node{
			clearName:     clear,
			kind:          nodeSymlink,
			cipherName:    cipherName,
			parentDirID:   parentDirID,
			ciphertextKey: folderPrefix + "symlink.c9r",
		}, true
	}
	return node{}, false
}

func (s *Session) nodeForShortened(cipherName, parentDirID, folderPrefix string) (node, bool) {
	nameBytes, err := s.store.Get(folderPrefix + "name.c9s")
	if err != nil {
		return node{}, false
	}
	longName := strings.TrimSpace(string(nameBytes))
	bare := longName
	if strings.HasSuffix(longName, ".c9r") {
		bare = strings.TrimSuffix(longName, ".c9r")
	}
	clear, err := s.cryptor.DecryptFileName(bare, parentDirID)
	if err != nil {
		return node{}, false
	}
	if dirBytes, err := s.store.Get(folderPrefix + "dir.c9r"); err == nil {
		childID := strings.TrimSpace(string(dirBytes))
		return node{
			clearName:     clear,
			kind:          nodeDir,
			cipherName:    cipherName,
			parentDirID:   parentDirID,
			dirID:         childID,
			ciphertextKey: folderPrefix + "dir.c9r",
		}, true
	}
	contentsKey := folderPrefix + "contents.c9r"
	if s.store.Exists(contentsKey) {
		return node{
			clearName:     clear,
			kind:          nodeFile,
			cipherName:    cipherName,
			parentDirID:   parentDirID,
			ciphertextKey: contentsKey,
		}, true
	}
	if s.store.Exists(folderPrefix + "symlink.c9r") {
		return node{
			clearName:     clear,
			kind:          nodeSymlink,
			cipherName:    cipherName,
			parentDirID:   parentDirID,
			ciphertextKey: folderPrefix + "symlink.c9r",
		}, true
	}
	return node{}, false
}

func (s *Session) resolve(cleartextPath string) (node, error) {
	parts := splitPath(cleartextPath)
	if len(parts) == 0 {
		return node{}, fmt.Errorf("%w: %s", errNotFound, cleartextPath)
	}
	dirID := ""
	for i, part := range parts {
		nodes, err := s.listDir(dirID)
		if err != nil {
			return node{}, err
		}
		var match *node
		for j := range nodes {
			if nodes[j].clearName == part {
				match = &nodes[j]
				break
			}
		}
		if match == nil {
			return node{}, fmt.Errorf("%w: %s", errNotFound, cleartextPath)
		}
		if i == len(parts)-1 {
			return *match, nil
		}
		if match.kind != nodeDir || match.dirID == "" {
			return node{}, fmt.Errorf("%w: %s", errNotFound, cleartextPath)
		}
		dirID = match.dirID
	}
	return node{}, fmt.Errorf("%w: %s", errNotFound, cleartextPath)
}

func normalizePath(p string) string {
	if p == "" || p == "/" {
		return "/"
	}
	if !strings.HasPrefix(p, "/") {
		p = "/" + p
	}
	p = path.Clean(p)
	if p == "." {
		return "/"
	}
	return p
}

func splitPath(p string) []string {
	p = normalizePath(p)
	if p == "/" {
		return nil
	}
	var parts []string
	for _, s := range strings.Split(strings.Trim(p, "/"), "/") {
		if s != "" {
			parts = append(parts, s)
		}
	}
	return parts
}

func joinClear(parent, name string) string {
	if parent == "/" {
		return "/" + name
	}
	return parent + "/" + name
}
