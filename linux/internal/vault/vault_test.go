package vault

import (
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/guillebot/cryptomako/linux/internal/config"
)

func fixturesDir(t *testing.T) string {
	t.Helper()
	// linux/internal/vault → repo root fixtures/
	dir := filepath.Join("..", "..", "..", "fixtures")
	abs, err := filepath.Abs(dir)
	if err != nil {
		t.Fatal(err)
	}
	return abs
}

func fixturePassword(t *testing.T) (string, bool) {
	t.Helper()
	path := filepath.Join(fixturesDir(t), "PASSWORD")
	data, err := os.ReadFile(path)
	if err != nil {
		return "", false
	}
	return strings.TrimSpace(string(data)), true
}

func TestUnlockLocalRequiresVaultFile(t *testing.T) {
	dir := t.TempDir()
	_, err := Unlock(config.Config{LocalRoot: dir, Passphrase: "x"})
	if err == nil {
		t.Fatal("expected missing vault.cryptomator")
	}
}

func TestCipherDirPrefix(t *testing.T) {
	got := CipherDirPrefix("vault", "aabbccddee")
	want := "vault/d/aa/bbccddee/"
	if got != want {
		t.Fatalf("got %q want %q", got, want)
	}
}

func TestUnlockRemoteNotImplemented(t *testing.T) {
	_, err := Unlock(config.Config{
		Endpoint:   "https://minio.example",
		Bucket:     "b",
		Passphrase: "x",
	})
	if err == nil {
		t.Fatal("expected not implemented")
	}
}

func TestFixtureUnlockListCat(t *testing.T) {
	pass, ok := fixturePassword(t)
	if !ok {
		t.Skip("fixtures/PASSWORD missing")
	}
	root := filepath.Join(fixturesDir(t), "vault")
	s, err := Unlock(config.Config{LocalRoot: root, Passphrase: pass})
	if err != nil {
		t.Fatalf("unlock: %v", err)
	}
	defer s.Close()

	if s.Format != Format8 {
		t.Fatalf("format = %d", s.Format)
	}
	if s.CipherCombo != "SIV_GCM" {
		t.Fatalf("cipherCombo = %q", s.CipherCombo)
	}
	if !strings.HasPrefix(s.RootCipherPrefix, "d/") || !strings.HasSuffix(s.RootCipherPrefix, "/") {
		t.Fatalf("rootPrefix = %q", s.RootCipherPrefix)
	}
	// Fixture root hash from Cryptomator layout
	if s.RootCipherPrefix != "d/FQ/QG7OOSQNZM6BJDZAIENVAOACYROMHW/" {
		t.Fatalf("unexpected rootPrefix %q", s.RootCipherPrefix)
	}

	entries, err := s.List("/", true)
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	var lines []string
	for _, e := range entries {
		name := e.Name
		if e.IsDir {
			name += "/"
		}
		lines = append(lines, name)
	}
	got := strings.Join(lines, "\n") + "\n"
	wantBytes, err := os.ReadFile(filepath.Join(fixturesDir(t), "expected-ls.txt"))
	if err != nil {
		t.Fatal(err)
	}
	want := string(wantBytes)
	if got != want {
		t.Fatalf("ls mismatch:\n--- want ---\n%s--- got ---\n%s", want, got)
	}

	r, err := s.Open("/hello.txt")
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer r.Close()
	body, err := io.ReadAll(r)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(body), "hello") {
		t.Fatalf("hello.txt body = %q", body)
	}

	// Long shortened name must resolve
	long := ""
	for _, e := range entries {
		if strings.Contains(e.Name, "nnnn") {
			long = e.Name
			break
		}
	}
	if long == "" {
		t.Fatal("missing shortened long filename entry")
	}
	r2, err := s.Open(long)
	if err != nil {
		t.Fatalf("open long: %v", err)
	}
	defer r2.Close()
	if _, err := io.ReadAll(r2); err != nil {
		t.Fatal(err)
	}
}

func TestWrongPasswordFailClosed(t *testing.T) {
	if _, ok := fixturePassword(t); !ok {
		t.Skip("fixtures/PASSWORD missing")
	}
	root := filepath.Join(fixturesDir(t), "vault")
	_, err := Unlock(config.Config{LocalRoot: root, Passphrase: "definitely-wrong-password"})
	if err == nil {
		t.Fatal("expected unlock failure")
	}
	msg := err.Error()
	for _, bad := range []string{"primaryMasterKey", "EncryptKey", "MacKey", "scryptSalt", "rawKey"} {
		if strings.Contains(msg, bad) {
			t.Fatalf("error leaked key material %q: %v", bad, err)
		}
	}
}

func TestShortenedNameNoPad(t *testing.T) {
	// SHA-1 → base64url without padding + .c9s
	got := ShortenedName("AaBbCcDdEeFfGgHhIiJjKkLlMmNnOoPpQqRrSsTtUuVvWwXxYyZz0123456789+/=======.c9r")
	if !strings.HasSuffix(got, ".c9s") {
		t.Fatalf("%q", got)
	}
	base := strings.TrimSuffix(got, ".c9s")
	if strings.Contains(base, "=") {
		t.Fatalf("padding present: %q", got)
	}
	if len(base) != 27 {
		t.Fatalf("len=%d %q", len(base), got)
	}
}
