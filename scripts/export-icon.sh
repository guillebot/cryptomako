#!/usr/bin/env bash
# Render Support/Brand/cryptomako-icon.svg into AppIcon.appiconset PNGs.
# Requires one of: rsvg-convert (brew install librsvg), inkscape, or qlmanage (macOS).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
svg="${root}/Support/Brand/cryptomako-icon.svg"
out="${root}/Support/Brand/Assets.xcassets/AppIcon.appiconset"
master="${out}/icon_1024.png"

mkdir -p "$out"

render_master() {
  if command -v rsvg-convert >/dev/null 2>&1; then
    rsvg-convert -w 1024 -h 1024 "$svg" -o "$master"
    return 0
  fi
  if command -v inkscape >/dev/null 2>&1; then
    inkscape "$svg" --export-type=png --export-filename="$master" -w 1024 -h 1024
    return 0
  fi
  if command -v qlmanage >/dev/null 2>&1; then
    tmp="$(mktemp -d)"
    cp "$svg" "$tmp/icon.svg"
    (cd "$tmp" && qlmanage -t -s 1024 -o . icon.svg >/dev/null 2>&1)
    mv "$tmp/icon.svg.png" "$master"
    rm -rf "$tmp"
    return 0
  fi
  echo "Install rsvg-convert (brew install librsvg) to export PNGs." >&2
  return 1
}

render_master

resize() {
  local name="$1"
  local size="$2"
  sips -z "$size" "$size" "$master" --out "${out}/${name}" >/dev/null
}

resize icon_16x16.png 16
resize icon_16x16@2x.png 32
resize icon_32x32.png 32
resize icon_32x32@2x.png 64
resize icon_128x128.png 128
resize icon_128x128@2x.png 256
resize icon_256x256.png 256
resize icon_256x256@2x.png 512
resize icon_512x512.png 512
resize icon_512x512@2x.png 1024

echo "Exported AppIcon PNGs to ${out}"
