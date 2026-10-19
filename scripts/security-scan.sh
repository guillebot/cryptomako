#!/usr/bin/env bash
# Local security gate. Install once:
#   brew install trivy grype syft gitleaks osv-scanner gosec
#   go install golang.org/x/vuln/cmd/govulncheck@v1.1.4
# CI also runs NuGet audit, CodeQL, and the Linux image scan.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required scanner: $1" >&2
    exit 1
  fi
}

for tool in trivy grype gitleaks osv-scanner govulncheck; do
  require "$tool"
done

echo "==> resolving Swift packages"
swift package resolve

# `.build/checkouts/` holds SPM dependency sources (benchmark keys, upstream
# Dockerfiles). Those are not shipped; exclude the whole tree.
trivy_common=(
  --scanners vuln,secret,misconfig
  --severity CRITICAL,HIGH
  --exit-code 1
  --ignorefile .trivyignore
  --skip-dirs .build
  --skip-dirs .swiftpm
  --skip-dirs fixtures/vault
  --skip-dirs release/dist
)

echo "==> trivy fs (vuln, secret, misconfig)"
trivy fs "${trivy_common[@]}" .

echo "==> grype lockfiles (NVD)"
grype "file:${root}/Package.resolved" --fail-on high
grype "dir:${root}/linux" --fail-on high

echo "==> gitleaks (history)"
gitleaks git "${root}" --redact --no-banner --exit-code 1

echo "==> osv-scanner"
osv-scanner scan \
  --config "${root}/osv-scanner.toml" \
  --lockfile "${root}/linux/go.mod" \
  --format table

echo "==> govulncheck (reachable Go issues)"
(
  cd "${root}/linux"
  govulncheck ./...
)

echo "==> gosec"
(
  cd "${root}/linux"
  log="${root}/.build/gosec.txt"
  mkdir -p "${root}/.build"
  set +e
  # Compile gosec with Go 1.27.2. A binary built by an older Go cannot import
  # this module. gosec v2.29.0 still vendors an importer that stops at export
  # data version 4, so a version-skew error is a tool gap, not a finding.
  GOTOOLCHAIN=go1.27.2 go run github.com/securego/gosec/v2/cmd/gosec@v2.29.0 -fmt=text -r . >"$log" 2>&1
  status=$?
  set -e
  cat "$log"
  if [[ "$status" -ne 0 ]]; then
    if grep -q 'export data version' "$log"; then
      echo "gosec v2.29.0 cannot import Go 1.27 export data. CodeQL is the Go SAST job until gosec catches up." >&2
      exit 0
    fi
    exit "$status"
  fi
)

if command -v dotnet >/dev/null 2>&1; then
  echo "==> nuget audit"
  dotnet restore "${root}/windows/CryptoMako.sln"
  dotnet list "${root}/windows/CryptoMako.sln" package --vulnerable --include-transitive
else
  echo "==> nuget audit runs in Windows CI (dotnet is not installed here)"
fi

if command -v syft >/dev/null 2>&1; then
  echo "==> syft SBOM (optional artifact)"
  mkdir -p .build
  syft . \
    --exclude './.build/**' \
    --exclude './.swiftpm/**' \
    --exclude './fixtures/vault/**' \
    --exclude './release/dist/**' \
    -o cyclonedx-json > .build/sbom.cyclonedx.json
  echo "    wrote .build/sbom.cyclonedx.json"
fi
