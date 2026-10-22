# Security

| Rule | PoC | Ship |
|------|-----|------|
| Crypto | `cryptolib-swift` only | same |
| Passphrase | environment | Keychain + optional biometry |
| S3 secret | environment | Keychain |
| Logs | no keys, no JWT, no passphrase | no cleartext names in crash reports |
| License | AGPLv3 | AGPLv3 |
| Audit | `make security` + GitHub CI | same, block release on HIGH+ |
| S3 transport | tests may inject HTTP | production clients require HTTPS, no URL userinfo |
| Signing key | Keychain / Application Support | never inside the repository |

## Dependency and secret scanning

CI (`.github/workflows/ci.yml`) runs on every push/PR:

- **Trivy** — vulnerability, secret, Dockerfile, and image scan. The image scan fails on HIGH or CRITICAL findings that already have a vendor fix. Does not scan `.build/checkouts/` (transitive SPM trees contain upstream Dockerfiles and benchmark keys that are not shipped).
- **Grype** — Anchore scanner using NVD and language-ecosystem feeds; fails on HIGH+.
- **OSV-Scanner** and **govulncheck** — Go vulnerability database, with govulncheck limited to reachable issues.
- **Gitleaks** — secret scan of the working tree and git history.
- **Gosec** — Go static analysis. gosec v2.29.0 cannot import Go 1.27 export data, so that specific tool error does not fail the gate. CodeQL analyzes the Go sources. Any other gosec finding still fails the gate.
- **NuGet audit** — Windows restore fails on HIGH+ (`NU1902`–`NU1904`).
- **CodeQL** — Go, C#, and Swift analysis on pull requests.

Release asset jobs call the same security workflow and do not upload unless it passes.

Local gate:

```bash
brew install trivy grype syft gitleaks osv-scanner  # once
go install golang.org/x/vuln/cmd/govulncheck@v1.9.0
go install github.com/google/osv-scanner/v2/cmd/osv-scanner@v2.7.0
git config core.hooksPath .githooks   # once per clone; pre-push runs the gate
make security                         # runs scripts/security-scan.sh
make sbom                             # optional CycloneDX SBOM in .build/
```

Document accepted findings in `.trivyignore` with a reason and review date.

## Input validation

`DirectoryObjectStore` rejects object keys containing `..` or leading `/` so a malicious key cannot escape the vault root on disk.

## Threat model (short)

The S3 host is untrusted. Compromise of the Mac while a vault is unlocked is treated as lost. Multi-device writers can orphan directories; do not invent a sidecar index object (it breaks other Cryptomator clients).

Wrong password and corrupt vault both surface as unlock failed. Do not distinguish them in logs.

Spotlight will index cleartext names once files hydrate (M2). Disclose that in the user-facing README before shipping.

## JWT

`vault.cryptomator` is a JWT signed with HMAC over the 512-bit raw masterkey (`aesMasterKey ‖ macMasterKey`). CryptoMako verifies the signature before trusting `format` / `cipherCombo` / `shorteningThreshold`.


## S3 HTTP client

`S3ObjectStore` uses an ephemeral `URLSession` with caching disabled. `URLSession.shared` can persist GET responses for `masterkey.cryptomator` / `vault.cryptomator`; after rewriting a vault prefix on the server, a stale cache makes unlock fail while `rclone`/boto still see the new objects.

Production macOS, Windows, and Linux clients accept only `https` endpoints and reject usernames or passwords embedded in the URL. Unit tests may inject an HTTP `URLSession`. The Linux container runs as a non-root user; a mount still needs `/dev/fuse` and either `CAP_SYS_ADMIN` or a setuid `fusermount3` supplied by the runtime.
