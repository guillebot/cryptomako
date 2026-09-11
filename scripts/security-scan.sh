#!/usr/bin/env bash
# Local security gate: Trivy (NVD) + Grype. Install via Homebrew:
#   brew install trivy grype syft
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

echo "==> resolving Swift packages"
swift package resolve

# `.build/checkouts/` holds SPM dependency sources (benchmark keys, upstream
# Dockerfiles). Those are not shipped; exclude the whole tree.
trivy_common=(
  --scanners vuln,secret
  --severity CRITICAL,HIGH
  --exit-code 1
  --ignorefile .trivyignore
  --skip-dirs .build
  --skip-dirs .swiftpm
  --skip-dirs fixtures/vault
)

fail=0

if command -v trivy >/dev/null 2>&1; then
  echo "==> trivy fs (vuln, secret)"
  trivy fs "${trivy_common[@]}" .
else
  echo "WARN: trivy not installed (brew install trivy)" >&2
  fail=1
fi

if command -v grype >/dev/null 2>&1; then
  echo "==> grype lockfile (Swift PM / NVD)"
  grype "file:${root}/Package.resolved" --fail-on high
else
  echo "WARN: grype not installed (brew install grype)" >&2
  fail=1
fi

if command -v syft >/dev/null 2>&1; then
  echo "==> syft SBOM (optional artifact)"
  mkdir -p .build
  syft . \
    --exclude './.build/**' \
    --exclude './.swiftpm/**' \
    --exclude './fixtures/vault/**' \
    -o cyclonedx-json > .build/sbom.cyclonedx.json
  echo "    wrote .build/sbom.cyclonedx.json"
fi

exit "$fail"
