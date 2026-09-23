#!/usr/bin/env bash
# Build a thin cryptomako .deb (binary + man + copyright + .desktop + hicolor icons + packaging README).
# Secrets are never packaged. Prefer dpkg-deb; fall back to nfpm when present.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${VERSION:-1.0.0}"
if [[ -n "${ARCH:-}" ]]; then
  :
elif command -v dpkg >/dev/null 2>&1; then
  ARCH="$(dpkg --print-architecture)"
elif [[ "$(uname -m)" == "aarch64" || "$(uname -m)" == "arm64" ]]; then
  ARCH=arm64
else
  ARCH=amd64
fi

DIST="$ROOT/packaging/dist"
mkdir -p "$DIST"
OUT="$DIST/cryptomako_${VERSION}_${ARCH}.deb"

echo "==> building cryptomako (CGO_ENABLED=0, linux/${ARCH})"
export CGO_ENABLED=0
case "$ARCH" in
  amd64) export GOARCH=amd64 ;;
  arm64) export GOARCH=arm64 ;;
  *) echo "unsupported ARCH=$ARCH (use amd64 or arm64)" >&2; exit 1 ;;
esac
export GOOS=linux
go build -trimpath -ldflags="-s -w" -o "$ROOT/cryptomako" .

if command -v dpkg-deb >/dev/null 2>&1; then
  STAGE="$(mktemp -d)"
  trap 'rm -rf "$STAGE"' EXIT
  mkdir -p \
    "$STAGE/usr/bin" \
    "$STAGE/usr/share/man/man1" \
    "$STAGE/usr/share/doc/cryptomako" \
    "$STAGE/usr/share/applications" \
    "$STAGE/usr/share/icons/hicolor/48x48/apps" \
    "$STAGE/usr/share/icons/hicolor/256x256/apps" \
    "$STAGE/usr/share/icons/hicolor/512x512/apps" \
    "$STAGE/DEBIAN"

  install -m 0755 "$ROOT/cryptomako" "$STAGE/usr/bin/cryptomako"
  install -m 0644 "$ROOT/packaging/man/cryptomako.1" "$STAGE/usr/share/man/man1/cryptomako.1"
  gzip -9fn "$STAGE/usr/share/man/man1/cryptomako.1"
  install -m 0644 "$ROOT/packaging/debian/copyright" "$STAGE/usr/share/doc/cryptomako/copyright"
  install -m 0644 "$ROOT/packaging/README.md" "$STAGE/usr/share/doc/cryptomako/README.md"
  install -m 0644 "$ROOT/packaging/cryptomako.desktop" "$STAGE/usr/share/applications/cryptomako.desktop"
  install -m 0644 "$ROOT/packaging/icons/hicolor/48x48/apps/cryptomako.png" \
    "$STAGE/usr/share/icons/hicolor/48x48/apps/cryptomako.png"
  install -m 0644 "$ROOT/packaging/icons/hicolor/256x256/apps/cryptomako.png" \
    "$STAGE/usr/share/icons/hicolor/256x256/apps/cryptomako.png"
  install -m 0644 "$ROOT/packaging/icons/hicolor/512x512/apps/cryptomako.png" \
    "$STAGE/usr/share/icons/hicolor/512x512/apps/cryptomako.png"

  cat > "$STAGE/DEBIAN/control" <<CTRL
Package: cryptomako
Version: ${VERSION}
Section: utils
Priority: optional
Architecture: ${ARCH}
Maintainer: CryptoMako <noreply@example.com>
Depends: fuse3
Description: Cryptomator format-8 vault CLI for Linux
 Unlock, browse, FUSE-mount, and Backup-Sync Cryptomator format-8
 (SIV_GCM) vaults over path-style HTTPS S3 or a local vault directory.
 Secrets stay in environment variables; never packaged.
CTRL

  # Installed-Size in KiB
  size_kb="$(du -sk "$STAGE/usr" | awk '{print $1}')"
  echo "Installed-Size: ${size_kb}" >> "$STAGE/DEBIAN/control"

  dpkg-deb --root-owner-group --build "$STAGE" "$OUT"
  echo "==> wrote $OUT"
  dpkg-deb -I "$OUT" || true
  exit 0
fi

if command -v nfpm >/dev/null 2>&1; then
  echo "==> dpkg-deb not found; using nfpm"
  ARCH="$ARCH" VERSION="$VERSION" nfpm package -f packaging/nfpm.yaml -p deb -t "$DIST"
  # nfpm may name the file differently; normalize if needed
  echo "==> packages in $DIST"
  ls -la "$DIST"
  exit 0
fi

echo "Neither dpkg-deb nor nfpm found." >&2
echo "On Debian/Ubuntu CI: apt-get install -y dpkg-dev" >&2
echo "Or: go install github.com/goreleaser/nfpm/v2/cmd/nfpm@latest" >&2
echo "Binary built at: $ROOT/cryptomako (GOOS=linux GOARCH=$ARCH)" >&2
exit 2
