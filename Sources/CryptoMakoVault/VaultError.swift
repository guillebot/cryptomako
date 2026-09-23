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
    case notADirectory(String)
    case invalidPath(String)
    case alreadyExists(String)
    case directoryNotEmpty(String)
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
        case .notADirectory(let path):
            return "not a directory: \(path)"
        case .invalidPath(let path):
            return "invalid path: \(path)"
        case .alreadyExists(let path):
            return "already exists: \(path)"
        case .directoryNotEmpty(let path):
            return "directory not empty: \(path)"
        case .store(let error):
            return error.localizedDescription
        }
    }
}
