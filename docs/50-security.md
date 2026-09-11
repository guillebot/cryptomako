# Security

| Rule | PoC | Ship |
|------|-----|------|
| Crypto | `cryptolib-swift` only | same |
| Passphrase | environment | Keychain + optional biometry |
| S3 secret | environment | Keychain |
| Logs | no keys, no JWT, no passphrase | no cleartext names in crash reports |
| License | AGPLv3 | same unless a Skymatic commercial license |
| Audit | none | before paid 1.0 |

## Threat model (short)

The S3 host is untrusted. Compromise of the Mac while a vault is unlocked is treated as lost. Multi-device writers can orphan directories; do not invent a sidecar index object (it breaks other Cryptomator clients).

Wrong password and corrupt vault both surface as unlock failed. Do not distinguish them in logs.

Spotlight will index cleartext names once files hydrate (M2). Disclose that in the user-facing README before shipping.

## JWT

`vault.cryptomator` is a JWT signed with HMAC over the 512-bit raw masterkey (`aesMasterKey ‖ macMasterKey`). CryptoMako verifies the signature before trusting `format` / `cipherCombo` / `shorteningThreshold`.
