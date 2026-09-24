#!/usr/bin/env bash
# CryptoMako release packaging: archive → Developer ID export → zip/dmg → notarize → staple
#
# Prerequisites (do these once before running):
#   1. Install Developer ID Application cert from Apple portal (CSR:
#      release/CryptoMako_DeveloperID.certSigningRequest). Import the .cer into
#      login keychain so codesign / Xcode export can see it.
#   2. App Store Connect API key for notarization (preferred), e.g.:
#        export APP_STORE_CONNECT_API_KEY_ID=...
#        export APP_STORE_CONNECT_ISSUER_ID=...
#        export APP_STORE_CONNECT_API_KEY_PATH=~/.appstoreconnect/private_keys/AuthKey_….p8
#      Or a notarytool keychain profile named CryptoMakoNotary:
#        xcrun notarytool store-credentials CryptoMakoNotary \
#          --apple-id "YOUR_APPLE_ID" --team-id "H4K6YW7MQM" \
#          --password "app-specific-password"
#   3. macFUSE.framework present at /Library/Frameworks (linked, not embedded).
#   4. Xcode-managed Mac Team Direct profiles for
#      net.gschimmel.cryptomako and net.gschimmel.cryptomako.FileProvider
#      (created automatically when the app IDs exist on the team).
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
DEVELOPER_ID_NAME="${DEVELOPER_ID_NAME:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-CryptoMakoNotary}"
SKIP_NOTARIZE=0
CONFIGURATION="Release"

for arg in "$@"; do
  case "$arg" in
    --skip-notarize) SKIP_NOTARIZE=1 ;;
    -h|--help)
      sed -n '2,30p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown arg: $arg" >&2
      exit 2
      ;;
  esac
done

die() { echo "error: $*" >&2; exit 1; }

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

VERSION="$(sed -n 's/.*MARKETING_VERSION: *"\([^"]*\)".*/\1/p' project.yml | head -1)"
BUILD="$(sed -n 's/.*CURRENT_PROJECT_VERSION: *"\([^"]*\)".*/\1/p' project.yml | head -1)"
[[ -n "$VERSION" && -n "$BUILD" ]] || die "could not parse MARKETING_VERSION / CURRENT_PROJECT_VERSION from project.yml"

DIST="$ROOT/release/dist"
STAGE="$DIST/CryptoMako-${VERSION}"
ZIP="$DIST/CryptoMako-${VERSION}.zip"
DMG="$DIST/CryptoMako-${VERSION}.dmg"
ARCHIVE="$DIST/CryptoMako.xcarchive"
EXPORT_DIR="$DIST/export"
EXPORT_PLIST="$DIST/ExportOptions.plist"
NOTARY_LOG="$DIST/CryptoMako-${VERSION}-notarization.json"
DMG_NOTARY_LOG="$DIST/CryptoMako-${VERSION}-dmg-notarization.json"
mkdir -p "$DIST"
rm -rf "$STAGE" "$ZIP" "$DMG" "$ARCHIVE" "$EXPORT_DIR" "$NOTARY_LOG" "$DMG_NOTARY_LOG"
mkdir -p "$STAGE"

echo "==> Regenerating Xcode project"
xcodegen generate

cat > "$EXPORT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>teamID</key>
	<string>${TEAM_ID}</string>
	<key>signingStyle</key>
	<string>automatic</string>
</dict>
</plist>
EOF

echo "==> Archiving ${CONFIGURATION} (Automatic → Developer ID export: ${DEVELOPER_ID_NAME})"
# Archive with Automatic (Apple Development). Xcode-managed Mac Team Direct
# profiles cannot be used with CODE_SIGN_STYLE=Manual. Export re-signs Developer ID.
xcodebuild archive \
  -project CryptoMako.xcodeproj \
  -scheme CryptoMako \
  -configuration "$CONFIGURATION" \
  -archivePath "$ARCHIVE" \
  -derivedDataPath "$DIST/DerivedData" \
  -destination 'generic/platform=macOS' \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  ENABLE_HARDENED_RUNTIME=YES

echo "==> Exporting Developer ID app"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_PLIST" \
  -allowProvisioningUpdates

APP_SRC="$EXPORT_DIR/CryptoMako.app"
[[ -d "$APP_SRC" ]] || die "export product missing: $APP_SRC"

echo "==> Staging app → $STAGE/CryptoMako.app"
ditto "$APP_SRC" "$STAGE/CryptoMako.app"

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$STAGE/CryptoMako.app"
spctl --assess --type execute -vv "$STAGE/CryptoMako.app" 2>&1 || true

echo "==> Zipping → $ZIP"
ditto -c -k --keepParent "$STAGE/CryptoMako.app" "$ZIP"

echo "==> Creating DMG → $DMG"
hdiutil create \
  -volname "CryptoMako ${VERSION}" \
  -srcfolder "$STAGE" \
  -ov -format UDZO \
  "$DMG"

notary_submit() {
  local artifact="$1"
  local out_log="$2"
  if [[ -n "${APP_STORE_CONNECT_API_KEY_PATH:-}" && -n "${APP_STORE_CONNECT_API_KEY_ID:-}" ]]; then
    local issuer="${APP_STORE_CONNECT_ISSUER_ID:-}"
    if [[ -z "$issuer" && -n "${ASC_JWT:-}" ]]; then
      issuer="$(python3 - <<'PY'
import os, base64, json
jwt = os.environ["ASC_JWT"]
p = jwt.split(".")[1]
p += "=" * (-len(p) % 4)
print(json.loads(base64.urlsafe_b64decode(p))["iss"])
PY
)"
    fi
    [[ -n "$issuer" ]] || die "Set APP_STORE_CONNECT_ISSUER_ID (or ASC_JWT) for API-key notarization"
    xcrun notarytool submit "$artifact" \
      --key "$APP_STORE_CONNECT_API_KEY_PATH" \
      --key-id "$APP_STORE_CONNECT_API_KEY_ID" \
      --issuer "$issuer" \
      --wait \
      --output-format json | tee "$out_log"
  else
    xcrun notarytool submit "$artifact" \
      --keychain-profile "$NOTARY_PROFILE" \
      --wait \
      --output-format json | tee "$out_log"
  fi
  python3 - "$out_log" <<'PY'
import json, sys
status = json.load(open(sys.argv[1]))["status"]
if status != "Accepted":
    raise SystemExit(f"notarization status={status}")
print(f"notarization Accepted ({sys.argv[1]})")
PY
}

if [[ "$SKIP_NOTARIZE" -eq 1 ]]; then
  echo "==> Skipping notarization (--skip-notarize)"
else
  echo "==> Submitting zip to Apple notary service"
  notary_submit "$ZIP" "$NOTARY_LOG"

  echo "==> Stapling ticket to app"
  xcrun stapler staple "$STAGE/CryptoMako.app"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$STAGE/CryptoMako.app" "$ZIP"

  echo "==> Recreating DMG from stapled app, notarizing + stapling DMG"
  rm -f "$DMG"
  hdiutil create \
    -volname "CryptoMako ${VERSION}" \
    -srcfolder "$STAGE" \
    -ov -format UDZO \
    "$DMG"
  notary_submit "$DMG" "$DMG_NOTARY_LOG"
  xcrun stapler staple "$DMG"

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
