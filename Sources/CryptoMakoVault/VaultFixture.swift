import CryptomatorCryptoLib
import Foundation
import Security

/// Builds a Cryptomator format-8 vault on disk (PoC fixture, not a general vault creator).
public enum VaultFixture {
    public static let helloContents = Data("hello cryptomako\n".utf8)
    public static let todoContents = Data("buy milk\nwalk the dog\n".utf8)
    public static let cafeName = "café résumé.txt"
    public static let cafeContents = Data("unicode filename check\n".utf8)
    public static let longName = String(repeating: "n", count: 180) + ".txt"
    public static let longContents = Data("shortened-name check\n".utf8)

    public static func create(at root: URL, passphrase: String) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: root.path) {
            try fm.removeItem(at: root)
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let masterkey = try Masterkey.createNew()
        let masterJSON = try MasterkeyFile.lock(
            masterkey: masterkey,
            vaultVersion: 999,
            passphrase: passphrase
        )
        let jti = UUID().uuidString
        let token = try VaultJWT.sign(
            header: [
                "alg": "HS256",
                "typ": "JWT",
                "kid": "masterkeyfile:masterkey.cryptomator",
            ],
            payload: [
                "format": 8,
                "shorteningThreshold": 220,
                "cipherCombo": "SIV_GCM",
                "jti": jti,
            ],
            rawKey: masterkey.rawKey
        )
        try Data(token.utf8).write(to: root.appendingPathComponent("vault.cryptomator"))
        try masterJSON.write(to: root.appendingPathComponent("masterkey.cryptomator"))

        let cryptor = Cryptor(masterkey: masterkey, scheme: .sivGcm)
        let rootDir = try directoryURL(vaultRoot: root, cryptor: cryptor, dirId: "")
        try fm.createDirectory(at: rootDir, withIntermediateDirectories: true)
        try Data().write(to: rootDir.appendingPathComponent("dirid.c9r"))

        try putFile(
            cryptor: cryptor,
            parentDirId: "",
            parentDir: rootDir,
            cleartextName: "hello.txt",
            contents: helloContents
        )
        try putFile(
            cryptor: cryptor,
            parentDirId: "",
            parentDir: rootDir,
            cleartextName: cafeName,
            contents: cafeContents
        )
        try putFile(
            cryptor: cryptor,
            parentDirId: "",
            parentDir: rootDir,
            cleartextName: longName,
            contents: longContents
        )

        let notesId = UUID().uuidString
        try putDirectory(
            vaultRoot: root,
            cryptor: cryptor,
            parentDirId: "",
            parentDir: rootDir,
            cleartextName: "notes",
            childDirId: notesId
        )
        let notesDir = try directoryURL(vaultRoot: root, cryptor: cryptor, dirId: notesId)
        try putFile(
            cryptor: cryptor,
            parentDirId: notesId,
            parentDir: notesDir,
            cleartextName: "todo.md",
            contents: todoContents
        )

        let binId = UUID().uuidString
        try putDirectory(
            vaultRoot: root,
            cryptor: cryptor,
            parentDirId: "",
            parentDir: rootDir,
            cleartextName: "bin",
            childDirId: binId
        )
        let binDir = try directoryURL(vaultRoot: root, cryptor: cryptor, dirId: binId)
        try putFile(
            cryptor: cryptor,
            parentDirId: binId,
            parentDir: binDir,
            cleartextName: "tiny.png",
            contents: tinyPNG
        )
    }

    public static func randomPassphrase() -> String {
        var bytes = [UInt8](repeating: 0, count: 18)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess)
        let raw = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "A")
            .replacingOccurrences(of: "/", with: "B")
            .replacingOccurrences(of: "=", with: "")
        return String(raw.prefix(24))
    }

    private static func directoryURL(vaultRoot: URL, cryptor: Cryptor, dirId: String) throws -> URL {
        let rel = try DirLayout.ciphertextDirectoryPrefix(prefix: "", cryptor: cryptor, dirId: dirId)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return vaultRoot.appendingPathComponent(rel, isDirectory: true)
    }

    private static func putDirectory(
        vaultRoot: URL,
        cryptor: Cryptor,
        parentDirId: String,
        parentDir: URL,
        cleartextName: String,
        childDirId: String
    ) throws {
        let enc = try cryptor.encryptFileName(cleartextName, dirId: Data(parentDirId.utf8)) + ".c9r"
        let folder = try nodeFolder(parentDir: parentDir, cryptor: cryptor, ciphertextFileName: enc)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(childDirId.utf8).write(to: folder.appendingPathComponent("dir.c9r"))
        let child = try directoryURL(vaultRoot: vaultRoot, cryptor: cryptor, dirId: childDirId)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try Data(childDirId.utf8).write(to: child.appendingPathComponent("dirid.c9r"))
    }

    private static func putFile(
        cryptor: Cryptor,
        parentDirId: String,
        parentDir: URL,
        cleartextName: String,
        contents: Data
    ) throws {
        let enc = try cryptor.encryptFileName(cleartextName, dirId: Data(parentDirId.utf8)) + ".c9r"
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let clearURL = tmp.appendingPathExtension("in")
        let cipherURL = tmp.appendingPathExtension("c9r")
        defer {
            try? FileManager.default.removeItem(at: clearURL)
            try? FileManager.default.removeItem(at: cipherURL)
        }
        try contents.write(to: clearURL)
        try cryptor.encryptContent(from: clearURL, to: cipherURL)
        let cipherData = try Data(contentsOf: cipherURL)

        if enc.count > 220 {
            let folder = try nodeFolder(parentDir: parentDir, cryptor: cryptor, ciphertextFileName: enc)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(enc.utf8).write(to: folder.appendingPathComponent("name.c9s"))
            try cipherData.write(to: folder.appendingPathComponent("contents.c9r"))
        } else {
            try cipherData.write(to: parentDir.appendingPathComponent(enc))
        }
    }

    private static func nodeFolder(parentDir: URL, cryptor: Cryptor, ciphertextFileName: String) throws -> URL {
        if ciphertextFileName.count > 220 {
            return parentDir.appendingPathComponent(DirLayout.shortenedName(ciphertextFileName: ciphertextFileName))
        }
        return parentDir.appendingPathComponent(ciphertextFileName)
    }

    /// 1×1 PNG, 67 bytes.
    public static let tinyPNG = Data([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
        0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
        0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
        0x42, 0x60, 0x82,
    ])
}
