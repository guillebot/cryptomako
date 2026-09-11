import Foundation
import CryptoMakoS3

public enum VaultError: Error, LocalizedError {
    case unlockFailed
    case unsupportedFormat(Int)
    case unsupportedCipherCombo(String)
    case missingVaultConfig
    case missingMasterkey
    case invalidJWT
    case pathNotFound(String)
    case notAFile(String)
    case store(ObjectStoreError)

    public var errorDescription: String? {
        switch self {
        case .unlockFailed:
            return "unlock failed"
        case .unsupportedFormat(let format):
            return "unsupported vault format \(format)"
        case .unsupportedCipherCombo(let combo):
            return "unsupported cipherCombo \(combo)"
        case .missingVaultConfig:
            return "vault.cryptomator is missing"
        case .missingMasterkey:
            return "masterkey.cryptomator is missing"
        case .invalidJWT:
            return "unlock failed"
        case .pathNotFound(let path):
            return "path not found: \(path)"
        case .notAFile(let path):
            return "not a file: \(path)"
        case .store(let error):
            return error.localizedDescription
        }
    }
}
