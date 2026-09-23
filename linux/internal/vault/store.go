package vault

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// objectStore is a minimal ciphertext object API (local FS first; S3 later).
type objectStore interface {
	Get(key string) ([]byte, error)
	Exists(key string) bool
	ListImmediate(prefix string) (objects []string, prefixes []string, err error)
}

type localStore struct {
	root string
}

func newLocalStore(root string) (*localStore, error) {
	abs, err := filepath.Abs(root)
	if err != nil {
		return nil, err
	}
	st, err := os.Stat(abs)
	if err != nil {
		return nil, fmt.Errorf("vault: local root: %w", err)
	}
	if !st.IsDir() {
		return nil, fmt.Errorf("vault: local root is not a directory")
	}
	return &localStore{root: abs}, nil
}

func (s *localStore) resolve(key string) (string, error) {
	key = strings.TrimPrefix(key, "/")
	clean := filepath.Clean(filepath.FromSlash(key))
	if clean == ".." || strings.HasPrefix(clean, ".."+string(os.PathSeparator)) {
		return "", fmt.Errorf("vault: invalid key")
	}
	full := filepath.Join(s.root, clean)
	if !strings.HasPrefix(full, s.root+string(os.PathSeparator)) && full != s.root {
		return "", fmt.Errorf("vault: invalid key")
	}
	return full, nil
}

func (s *localStore) Get(key string) ([]byte, error) {
	path, err := s.resolve(key)
	if err != nil {
		return nil, err
	}
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, errNotFound
		}
		return nil, err
	}
	return data, nil
}

func (s *localStore) Exists(key string) bool {
	path, err := s.resolve(key)
	if err != nil {
		return false
	}
	st, err := os.Stat(path)
	return err == nil && !st.IsDir()
}

func (s *localStore) ListImmediate(prefix string) (objects []string, prefixes []string, err error) {
	if prefix != "" && !strings.HasSuffix(prefix, "/") {
		prefix += "/"
	}
	dir, err := s.resolve(prefix)
	if err != nil {
		return nil, nil, err
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil, nil
		}
		return nil, nil, err
	}
	for _, e := range entries {
		name := e.Name()
		if e.IsDir() {
			prefixes = append(prefixes, prefix+name+"/")
		} else {
			objects = append(objects, prefix+name)
		}
	}
	return objects, prefixes, nil
}
