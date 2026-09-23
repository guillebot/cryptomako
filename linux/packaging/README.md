# Linux packaging sketch

## Exact install (no package manager)

```bash
cd linux
go test ./...
go build -o cryptomako .
sudo install -m 0755 cryptomako /usr/local/bin/cryptomako
sudo apt-get install -y fuse3   # Debian/Ubuntu; Fedora: fuse3
```

Runtime:

- `CRYPTOMAKO_PASSWORD` — vault passphrase (required)
- `CRYPTOMAKO_SECRET_KEY` — S3 secret (remote only)
- Non-secrets: `~/.config/cryptomako/config.json` or CLI flags (`endpoint`, `region`,
  `bucket`, `prefix`, `accessKeyId`). **No new settings keys** without Platforms.
- Path-style S3 is locked on (`PathStyle: true`).

## Thin `.deb` (future `nfpm` / `dpkg-deb`)

Suggested layout only — not built in CI yet:

| Path | Content |
|------|---------|
| `/usr/bin/cryptomako` | Go binary (`CGO_ENABLED=0`) |
| `Depends:` | `fuse3` |
| conffiles | none (user XDG config only) |

Do **not** ship password/secret templates. Do **not** add VaultSettings keys in the
package.

Example `nfpm.yaml` sketch:

```yaml
name: cryptomako
arch: amd64
platform: linux
version: 0.1.0
depends: [fuse3]
contents:
  - src: cryptomako
    dst: /usr/bin/cryptomako
    file_info: { mode: 0755 }
```

Build: `go build -o cryptomako . && nfpm package -p deb`.
