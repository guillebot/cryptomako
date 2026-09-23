#!/usr/bin/env bash
# FUSE smoke: mount a format-8 vault, read hello.txt, optionally exercise --rw, unmount.
# Intended for real Linux (or Docker with /dev/fuse passthrough).
# When fixtures/ are missing, creates a minimal vault via `cryptomako fixture`.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LINUX="$ROOT/linux"
FIXTURES="$ROOT/fixtures"
MNT="${CRYPTOMAKO_MNT:-/tmp/cryptomako-fuse-smoke}"
PASSWORD_FILE="$FIXTURES/PASSWORD"
RW="${CRYPTOMAKO_FUSE_RW:-0}"

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

VAULT="${CRYPTOMAKO_VAULT:-}"
if [[ -z "$VAULT" ]]; then
  if [[ -f "$PASSWORD_FILE" && -d "$FIXTURES/vault" ]]; then
    export CRYPTOMAKO_PASSWORD
    CRYPTOMAKO_PASSWORD="$(tr -d '\n' < "$PASSWORD_FILE")"
    VAULT="$FIXTURES/vault"
  else
    echo "fixtures missing; creating minimal vault for smoke" >&2
    export CRYPTOMAKO_PASSWORD="${CRYPTOMAKO_PASSWORD:-ci-fuse-smoke-password}"
    VAULT="${CRYPTOMAKO_VAULT_OUT:-/tmp/cryptomako-fuse-vault}"
    rm -rf "$VAULT"
    "$BIN" fixture --output "$VAULT"
  fi
else
  if [[ -z "${CRYPTOMAKO_PASSWORD:-}" ]]; then
    if [[ -f "$PASSWORD_FILE" ]]; then
      export CRYPTOMAKO_PASSWORD
      CRYPTOMAKO_PASSWORD="$(tr -d '\n' < "$PASSWORD_FILE")"
    else
      echo "CRYPTOMAKO_PASSWORD required when CRYPTOMAKO_VAULT is set without fixtures/PASSWORD" >&2
      exit 1
    fi
  fi
fi

mkdir -p "$MNT"
cleanup() {
  if mountpoint -q "$MNT" 2>/dev/null || mount | grep -q " $MNT "; then
    fusermount3 -u "$MNT" 2>/dev/null || fusermount -u "$MNT" 2>/dev/null || umount "$MNT" 2>/dev/null || true
  fi
  rmdir "$MNT" 2>/dev/null || true
}
trap cleanup EXIT

MOUNT_FLAGS=(mount --local "$VAULT" --mountpoint "$MNT")
if [[ "$RW" == "1" || "$RW" == "true" ]]; then
  MOUNT_FLAGS+=(--rw)
fi

"$BIN" "${MOUNT_FLAGS[@]}" &
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

if [[ "$RW" == "1" || "$RW" == "true" ]]; then
  echo "rw-smoke" > "$MNT/rw-smoke.txt"
  got_rw="$(cat "$MNT/rw-smoke.txt")"
  if [[ "$got_rw" != "rw-smoke" ]]; then
    echo "rw write/read mismatch: $got_rw" >&2
    kill "$MPID" 2>/dev/null || true
    wait "$MPID" 2>/dev/null || true
    exit 1
  fi
  mv "$MNT/rw-smoke.txt" "$MNT/rw-renamed.txt"
  rm -f "$MNT/rw-renamed.txt"
  mkdir "$MNT/rw-dir"
  rmdir "$MNT/rw-dir"
  echo "FUSE smoke OK: rw create/write/rename/unlink/mkdir"
fi

kill -INT "$MPID" 2>/dev/null || true
wait "$MPID" 2>/dev/null || true
cleanup
trap - EXIT
echo "unmounted cleanly"
