#!/usr/bin/env bash
# FUSE smoke: mount fixtures vault read-only, read hello.txt, unmount.
# Intended for real Linux (or Docker with /dev/fuse passthrough).
# Docker Desktop on macOS typically cannot expose /dev/fuse — use a Linux host/CI.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LINUX="$ROOT/linux"
FIXTURES="$ROOT/fixtures"
VAULT="$FIXTURES/vault"
MNT="${CRYPTOMAKO_MNT:-/tmp/cryptomako-fuse-smoke}"
PASSWORD_FILE="$FIXTURES/PASSWORD"

if [[ ! -f "$PASSWORD_FILE" ]]; then
  echo "missing $PASSWORD_FILE (gitignored)" >&2
  exit 1
fi
export CRYPTOMAKO_PASSWORD
CRYPTOMAKO_PASSWORD="$(tr -d '\n' < "$PASSWORD_FILE")"

if [[ ! -e /dev/fuse ]]; then
  echo "BLOCKER: /dev/fuse not present on this host (expected on bare macOS)." >&2
  echo "Use Docker with: --device /dev/fuse --cap-add SYS_ADMIN --security-opt apparmor:unconfined" >&2
  echo "See linux/README.md Docker FUSE smoke, or run this script inside that container / on Linux CI." >&2
  exit 2
fi

BIN="${CRYPTOMAKO_BIN:-}"
if [[ -z "$BIN" ]]; then
  (cd "$LINUX" && go build -o /tmp/cryptomako-fuse-smoke .)
  BIN=/tmp/cryptomako-fuse-smoke
fi

mkdir -p "$MNT"
cleanup() {
  if mountpoint -q "$MNT" 2>/dev/null || mount | grep -q " $MNT "; then
    fusermount3 -u "$MNT" 2>/dev/null || fusermount -u "$MNT" 2>/dev/null || umount "$MNT" 2>/dev/null || true
  fi
  rmdir "$MNT" 2>/dev/null || true
}
trap cleanup EXIT

"$BIN" mount --local "$VAULT" --mountpoint "$MNT" &
MPID=$!
# Wait for hello.txt to appear
for i in $(seq 1 50); do
  if [[ -f "$MNT/hello.txt" ]]; then
    break
  fi
  sleep 0.1
done
if [[ ! -f "$MNT/hello.txt" ]]; then
  echo "mount did not expose hello.txt" >&2
  kill "$MPID" 2>/dev/null || true
  wait "$MPID" 2>/dev/null || true
  exit 1
fi

got="$(cat "$MNT/hello.txt")"
expect="hello cryptomako"
if [[ "$got" != *"$expect"* ]]; then
  echo "unexpected cleartext: $got" >&2
  kill "$MPID" 2>/dev/null || true
  wait "$MPID" 2>/dev/null || true
  exit 1
fi
echo "FUSE smoke OK: read cleartext hello.txt"

kill -INT "$MPID" 2>/dev/null || true
wait "$MPID" 2>/dev/null || true
# Explicit unmount if still mounted
cleanup
trap - EXIT
echo "unmounted cleanly"
