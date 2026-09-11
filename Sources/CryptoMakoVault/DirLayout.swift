import CryptomatorCryptoLib
import CryptoKit
import Foundation

enum DirLayout {
    static func ciphertextDirectoryPrefix(prefix: String, cryptor: Cryptor, dirId: String) throws -> String {
        let hash = try cryptor.encryptDirId(Data(dirId.utf8)).replacingOccurrences(of: "=", with: "")
        guard hash.count >= 3 else {
            throw VaultError.unlockFailed
        }
        let head = String(hash.prefix(2))
        let tail = String(hash.dropFirst(2))
        return prefix + "d/" + head + "/" + tail + "/"
    }

    static func shortenedName(ciphertextFileName: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data(ciphertextFileName.utf8))
        let b64 = Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return b64 + ".c9s"
    }
}
