# Security

| Rule | PoC | Ship |
|------|-----|------|
| Crypto | `cryptolib-swift` only | same |
| Passphrase | environment | Keychain + optional biometry |
| S3 secret | environment | Keychain |
| Logs | no keys, no JWT, no passphrase | no cleartext names in crash reports |
| License | AGPLv3 | AGPLv3 |
| Audit | `make security` + GitHub CI (Trivy/Grype) | same, block release on HIGH+ |

## Dependency and secret scanning

CI (`.github/workflows/ci.yml`) runs on every push/PR:

- **Trivy** — vulnerability and secret scan on first-party paths (`Sources/`, `Tests/`, `Package.resolved`, etc.). Does not scan `.build/checkouts/` (transitive SPM trees contain upstream Dockerfiles and benchmark keys that are not shipped).
- **Grype** — Anchore scanner using NVD and language-ecosystem feeds; same path exclusions; fails on HIGH+.

Local gate:

```bash
brew install trivy grype syft   # once
make security                   # runs scripts/security-scan.sh
make sbom                       # optional CycloneDX SBOM in .build/
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
