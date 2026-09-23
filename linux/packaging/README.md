# Linux packaging

Thin `.deb` for the CryptoMako CLI: binary + man page + this README snippet.
**No secrets** are packaged. User config stays under XDG (`~/.config/cryptomako/`).

## Build the `.deb`

From `linux/`:

```bash
./packaging/build-deb.sh
# → packaging/dist/cryptomako_${VERSION}_${ARCH}.deb

# Optional overrides:
VERSION=0.1.0 ARCH=amd64 ./packaging/build-deb.sh
```

Requires **dpkg-deb** (Debian/Ubuntu) or **nfpm**. The script cross-compiles
`GOOS=linux` with `CGO_ENABLED=0`.

Install:

```bash
sudo dpkg -i packaging/dist/cryptomako_*.deb
# or: sudo apt-get install -y ./packaging/dist/cryptomako_*.deb
# Depends: fuse3
```

Exact install without a package:

```bash
cd linux
go test ./...
CGO_ENABLED=0 go build -o cryptomako .
sudo install -m 0755 cryptomako /usr/local/bin/cryptomako
sudo apt-get install -y fuse3   # Debian/Ubuntu; Fedora: fuse3
```

## Runtime (env-only secrets)

| Env | Role |
|-----|------|
| `CRYPTOMAKO_PASSWORD` | Vault passphrase (required) |
| `CRYPTOMAKO_SECRET_KEY` | S3 secret (remote only) |

Non-secrets: `~/.config/cryptomako/config.json` or CLI flags. **No new settings keys**
without Platforms. Path-style S3 is locked on (`pathStyle` default `true`).

## Package layout

| Path | Content |
|------|---------|
| `/usr/bin/cryptomako` | Go binary (`CGO_ENABLED=0`) |
| `/usr/share/man/man1/cryptomako.1.gz` | Man page |
| `/usr/share/doc/cryptomako/` | copyright + packaging README |
| `Depends:` | `fuse3` |
| conffiles | none (user XDG config only) |

## nfpm alternative

```bash
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o cryptomako .
ARCH=amd64 VERSION=0.1.0 nfpm package -f packaging/nfpm.yaml -p deb -t packaging/dist
```

CI uploads the `.deb` as a workflow artifact (`cryptomako-deb`).
