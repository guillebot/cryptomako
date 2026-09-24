#!/usr/bin/env bash
# CryptoMako release packaging: Developer ID sign → zip → notarize → staple → stage under release/dist/
#
# Prerequisites (do these once before running):
#   1. Install Developer ID Application cert from Apple portal (CSR:
#      release/CryptoMako_DeveloperID.certSigningRequest). Import the .cer into
#      login keychain so codesign can see it.
#   2. Create notarytool keychain profile named CryptoMakoNotary, e.g.:
#        xcrun notarytool store-credentials CryptoMakoNotary \
#          --apple-id "YOUR_APPLE_ID" \
#          --team-id "H4K6YW7MQM" \
#          --password "app-specific-password"
#   3. macFUSE.framework present at /Library/Frameworks (linked, not embedded).
#
# Usage:
#   ./scripts/make-release.sh              # full pipeline
#   ./scripts/make-release.sh --skip-notarize   # build+zip+dmg only (no Apple upload)
#   DEVELOPER_ID_NAME='Developer ID Application: …' ./scripts/make-release.sh
#
# Outputs (under release/dist/):
#   CryptoMako-<version>.app (copy), .zip, .dmg, and notarization log.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

TEAM_ID="${DEVELOPMENT_TEAM:-H4K6YW7MQM}"
BUNDLE_ID="net.gschimmel.cryptomako"
# Placeholder: set via env once the Developer ID Application cert is installed.
# Example: "Developer ID Application: GUILLERMO GERMAN EDUARDO SCHIMMEL (H4K6YW7MQM)"
DEVELOPER_ID_NAME="${DEVELOPER_ID_NAME:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-CryptoMakoNotary}"
SKIP_NOTARIZE=0
CONFIGURATION="Release"

for arg in "$@"; do
  case "$arg" in
    --skip-notarize) SKIP_NOTARIZE=1 ;;
    -h|--help)
      sed -n '2,25p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown arg: $arg" >&2
      exit 2
      ;;
  esac
done

die() { echo "error: $*" >&2; exit 1; }

# Resolve signing identity if not provided.
if [[ -z "$DEVELOPER_ID_NAME" ]]; then
  DEVELOPER_ID_NAME="$(
    security find-identity -v -p codesigning 2>/dev/null \
      | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' \
      | head -1
  )"
fi
[[ -n "$DEVELOPER_ID_NAME" ]] || die \
  "No Developer ID Application identity found. Install the cert from Apple, then re-run, or set:
  DEVELOPER_ID_NAME='Developer ID Application: YOUR NAME (H4K6YW7MQM)'"

command -v xcodegen >/dev/null || die "xcodegen not found (brew install xcodegen)"
command -v xcodebuild >/dev/null || die "xcodebuild not found"

# Read marketing version from project.yml (single source of truth).
VERSION="$(sed -n 's/.*MARKETING_VERSION: *"\([^"]*\)".*/\1/p' project.yml | head -1)"
BUILD="$(sed -n 's/.*CURRENT_PROJECT_VERSION: *"\([^"]*\)".*/\1/p' project.yml | head -1)"
[[ -n "$VERSION" && -n "$BUILD" ]] || die "could not parse MARKETING_VERSION / CURRENT_PROJECT_VERSION from project.yml"

DIST="$ROOT/release/dist"
STAGE="$DIST/CryptoMako-${VERSION}"
ZIP="$DIST/CryptoMako-${VERSION}.zip"
DMG="$DIST/CryptoMako-${VERSION}.dmg"
NOTARY_LOG="$DIST/CryptoMako-${VERSION}-notarization.json"
mkdir -p "$DIST"
rm -rf "$STAGE" "$ZIP" "$DMG" "$NOTARY_LOG"
mkdir -p "$STAGE"

echo "==> Regenerating Xcode project"
xcodegen generate

echo "==> Building ${CONFIGURATION} (signed: ${DEVELOPER_ID_NAME})"
# Manual Developer ID signing for distribution outside the Mac App Store.
# CODE_SIGN_STYLE=Manual avoids Automatic trying to use Apple Development.
# Per-target Mac Team Direct profiles are set in project.yml Release configs.
xcodebuild \
  -project CryptoMako.xcodeproj \
  -scheme CryptoMako \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DIST/DerivedData" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$DEVELOPER_ID_NAME" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  ENABLE_HARDENED_RUNTIME=YES \
  build

APP_SRC="$DIST/DerivedData/Build/Products/${CONFIGURATION}/CryptoMako.app"
[[ -d "$APP_SRC" ]] || die "build product missing: $APP_SRC"

echo "==> Staging app → $STAGE/CryptoMako.app"
ditto "$APP_SRC" "$STAGE/CryptoMako.app"

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$STAGE/CryptoMako.app"
spctl --assess --type execute -vv "$STAGE/CryptoMako.app" 2>&1 || true
# spctl may fail until notarized; codesign --verify is the hard gate pre-notary.

echo "==> Zipping → $ZIP"
ditto -c -k --keepParent "$STAGE/CryptoMako.app" "$ZIP"

echo "==> Creating DMG → $DMG"
# Simple read-only UDZO dmg; replace with create-dmg later if branding needed.
hdiutil create \
  -volname "CryptoMako ${VERSION}" \
  -srcfolder "$STAGE" \
  -ov -format UDZO \
  "$DMG"

if [[ "$SKIP_NOTARIZE" -eq 1 ]]; then
  echo "==> Skipping notarization (--skip-notarize)"
else
  echo "==> Submitting zip to Apple notary service (profile: $NOTARY_PROFILE)"
  # Assumes keychain profile CryptoMakoNotary already stored (see header).
  xcrun notarytool submit "$ZIP" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait \
    --output-format json \
    | tee "$NOTARY_LOG"

  echo "==> Stapling ticket to app + dmg"
  xcrun stapler staple "$STAGE/CryptoMako.app"
  xcrun stapler staple "$DMG"
  # Re-zip stapled app so the zip carries the ticket too.
  rm -f "$ZIP"
  ditto -c -k --keepParent "$STAGE/CryptoMako.app" "$ZIP"

  echo "==> Post-staple Gatekeeper check"
  spctl --assess --type execute -vv "$STAGE/CryptoMako.app"
fi

echo
echo "Release artifacts ready:"
echo "  app:  $STAGE/CryptoMako.app"
echo "  zip:  $ZIP"
echo "  dmg:  $DMG"
[[ -f "$NOTARY_LOG" ]] && echo "  log:  $NOTARY_LOG"
echo "  version: ${VERSION} (${BUILD})  team: ${TEAM_ID}  bundle: ${BUNDLE_ID}"
