package vault

import (
	"fmt"
	"strings"
	"sync"
)

// memStore is an in-memory objectStore for tests (fail-injection included).
type memStore struct {
	mu         sync.Mutex
	objects    map[string][]byte
	failPut    bool
	failDelete bool
}

func newMemStore() *memStore {
	return &memStore{objects: make(map[string][]byte)}
}

func (m *memStore) Get(key string) ([]byte, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	data, ok := m.objects[key]
	if !ok {
		return nil, errNotFound
	}
	out := make([]byte, len(data))
	copy(out, data)
	return out, nil
}

func (m *memStore) Exists(key string) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	_, ok := m.objects[key]
	return ok
}

func (m *memStore) ListImmediate(prefix string) (objects []string, prefixes []string, err error) {
	if prefix != "" && !strings.HasSuffix(prefix, "/") {
		prefix += "/"
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	seenPfx := map[string]bool{}
	for k := range m.objects {
		if !strings.HasPrefix(k, prefix) {
			continue
		}
		rest := strings.TrimPrefix(k, prefix)
		if rest == "" {
			continue
		}
		if i := strings.IndexByte(rest, '/'); i >= 0 {
			p := prefix + rest[:i+1]
			if !seenPfx[p] {
				seenPfx[p] = true
				prefixes = append(prefixes, p)
			}
			continue
		}
		objects = append(objects, k)
	}
	return objects, prefixes, nil
}

func (m *memStore) Put(key string, data []byte) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.failPut {
		return fmt.Errorf("memStore: put failed (injected)")
	}
	cp := make([]byte, len(data))
	copy(cp, data)
	m.objects[key] = cp
	return nil
}

func (m *memStore) Delete(key string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.failDelete {
		return fmt.Errorf("memStore: delete failed (injected)")
	}
	delete(m.objects, key)
	return nil
}
