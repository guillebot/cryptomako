import CryptomatorCryptoLib
import Foundation
import CryptoMakoS3

public final class VaultSession: @unchecked Sendable {
    public let location: VaultLocation
    public let config: VaultConfig
    public let cryptor: Cryptor
    public let rootCipherPrefix: String

    private let store: any ObjectStore

    public init(location: VaultLocation, config: VaultConfig, cryptor: Cryptor, store: any ObjectStore) throws {
        self.location = location
        self.config = config
        self.cryptor = cryptor
        self.store = store
        self.rootCipherPrefix = try DirLayout.ciphertextDirectoryPrefix(
            prefix: location.prefix,
            cryptor: cryptor,
            dirId: ""
        )
    }

    public static func unlock(
        location: VaultLocation,
        passphrase: String,
        store: any ObjectStore
    ) async throws -> VaultSession {
        let jwtData: Data
        do {
            jwtData = try await store.getObject(key: location.key("vault.cryptomator"))
        } catch ObjectStoreError.notFound {
            throw VaultError.missingVaultConfig
        }
        guard let jwt = String(data: jwtData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !jwt.isEmpty
        else {
            throw VaultError.missingVaultConfig
        }

        let unverified: VaultJWT.Payload
        do {
            (_, unverified, _) = try VaultJWT.decodeUnverified(jwt)
        } catch {
            throw VaultError.unlockFailed
        }
        if unverified.format != 8 {
            throw VaultError.unsupportedFormat(unverified.format)
        }

        let masterData: Data
        do {
            masterData = try await store.getObject(key: location.key("masterkey.cryptomator"))
        } catch ObjectStoreError.notFound {
            throw VaultError.missingMasterkey
        }

        let masterkey: Masterkey
        do {
            let file = try MasterkeyFile.withContentFromData(data: masterData)
            masterkey = try file.unlock(passphrase: passphrase)
        } catch {
            throw VaultError.unlockFailed
        }

        let payload: VaultJWT.Payload
        do {
            payload = try VaultJWT.verify(token: jwt, rawKey: masterkey.rawKey)
        } catch {
            throw VaultError.unlockFailed
        }
        if payload.format != 8 {
            throw VaultError.unsupportedFormat(payload.format)
        }

        let scheme: CryptorScheme
        switch payload.cipherCombo {
        case CryptorScheme.sivGcm.rawValue:
            scheme = .sivGcm
        case CryptorScheme.sivCtrMac.rawValue:
            scheme = .sivCtrMac
        default:
            throw VaultError.unsupportedCipherCombo(payload.cipherCombo)
        }

        let cryptor = Cryptor(masterkey: masterkey, scheme: scheme)
        let config = VaultConfig(
            format: payload.format,
            shorteningThreshold: payload.shorteningThreshold ?? 220,
            cipherCombo: payload.cipherCombo,
            jti: payload.jti,
            kid: try? VaultJWT.decodeUnverified(jwt).0.kid
        )
        return try VaultSession(location: location, config: config, cryptor: cryptor, store: store)
    }

    public func list(dirId: String = "") async throws -> [VaultNode] {
        let dirPrefix = try DirLayout.ciphertextDirectoryPrefix(
            prefix: location.prefix,
            cryptor: cryptor,
            dirId: dirId
        )
        let listing = try await store.listImmediate(prefix: dirPrefix)
        var nodes: [VaultNode] = []

        for object in listing.objects {
            let name = relativeName(object.key, prefix: dirPrefix)
            guard !name.contains("/"), !name.isEmpty else { continue }
            if name == "dirid.c9r" {
                continue
            }
            if name.hasSuffix(".c9r"), let node = try await nodeForFileObject(
                name: name,
                parentDirId: dirId,
                object: object
            ) {
                nodes.append(node)
            }
        }

        for common in listing.commonPrefixes {
            let name = relativeName(String(common.dropLast(common.hasSuffix("/") ? 1 : 0)), prefix: dirPrefix)
            let folderName = relativeName(common, prefix: dirPrefix).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let cipherName = folderName.isEmpty ? name : folderName
            guard !cipherName.isEmpty, !cipherName.contains("/") else { continue }
            if let node = try await nodeForDirectoryPrefix(
                cipherName: cipherName,
                parentDirId: dirId,
                fullPrefix: common
            ) {
                nodes.append(node)
            }
        }

        nodes.sort { $0.cleartextName.localizedStandardCompare($1.cleartextName) == .orderedAscending }
        return nodes
    }

    public func listRecursive(at cleartextPath: String = "/") async throws -> [(String, VaultNode)] {
        var results: [(String, VaultNode)] = []
        try await walk(dirId: "", path: normalized(cleartextPath), into: &results)
        return results
    }

    public func cat(cleartextPath: String) async throws -> Data {
        let node = try await resolveFile(cleartextPath: cleartextPath)
        let clearURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cryptomako-\(UUID().uuidString).out")
        defer { try? FileManager.default.removeItem(at: clearURL) }
        try await fetch(node: node, to: clearURL)
        return try Data(contentsOf: clearURL)
    }

    /// Downloads ciphertext and decrypts straight to `destination`.
    ///
    /// The File Provider hands us a destination URL and large files should never
    /// pass through memory, so decryption is file-to-file.
    public func fetch(node: VaultNode, to destination: URL) async throws {
        let cipherURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cryptomako-\(UUID().uuidString).c9r")
        defer { try? FileManager.default.removeItem(at: cipherURL) }
        try await store.getObject(key: node.ciphertextKey, to: cipherURL)
        try cryptor.decryptContent(from: cipherURL, to: destination)
    }

    public func resolve(cleartextPath: String) async throws -> VaultNode {
        let parts = split(cleartextPath)
        guard !parts.isEmpty else {
            throw VaultError.pathNotFound(cleartextPath)
        }
        var dirId = ""
        for (index, part) in parts.enumerated() {
            let nodes = try await list(dirId: dirId)
            guard let match = nodes.first(where: { $0.cleartextName == part }) else {
                throw VaultError.pathNotFound(cleartextPath)
            }
            let last = index == parts.count - 1
            if last {
                return match
            }
            guard match.kind == .directory, let child = match.dirId else {
                throw VaultError.pathNotFound(cleartextPath)
            }
            dirId = child
        }
        throw VaultError.pathNotFound(cleartextPath)
    }

    public func resolveFile(cleartextPath: String) async throws -> VaultNode {
        let node = try await resolve(cleartextPath: cleartextPath)
        guard node.kind == .file else {
            throw VaultError.notAFile(cleartextPath)
        }
        return node
    }

    private func walk(dirId: String, path: String, into results: inout [(String, VaultNode)]) async throws {
        let nodes = try await list(dirId: dirId)
        for node in nodes {
            let childPath = path == "/" ? "/\(node.cleartextName)" : "\(path)/\(node.cleartextName)"
            results.append((childPath, node))
            if node.kind == .directory, let childId = node.dirId {
                try await walk(dirId: childId, path: childPath, into: &results)
            }
        }
    }

    private func nodeForFileObject(name: String, parentDirId: String, object: ListedObject) async throws -> VaultNode? {
        let cipherBare = String(name.dropLast(4)) // strip .c9r
        let clear: String
        do {
            clear = try cryptor.decryptFileName(cipherBare, dirId: Data(parentDirId.utf8))
        } catch {
            return nil
        }
        return VaultNode(
            cleartextName: clear,
            kind: .file,
            cipherName: name,
            parentDirId: parentDirId,
            dirId: nil,
            ciphertextKey: object.key,
            size: object.size,
            eTag: object.eTag
        )
    }

    private func nodeForDirectoryPrefix(cipherName: String, parentDirId: String, fullPrefix: String) async throws -> VaultNode? {
        let folderPrefix = fullPrefix.hasSuffix("/") ? fullPrefix : fullPrefix + "/"
        if cipherName.hasSuffix(".c9s") {
            return try await nodeForShortened(cipherName: cipherName, parentDirId: parentDirId, folderPrefix: folderPrefix)
        }
        guard cipherName.hasSuffix(".c9r") else {
            return nil
        }
        let cipherBare = String(cipherName.dropLast(4))
        let clear: String
        do {
            clear = try cryptor.decryptFileName(cipherBare, dirId: Data(parentDirId.utf8))
        } catch {
            return nil
        }
        if let dirBytes = try? await store.getObject(key: folderPrefix + "dir.c9r"),
           let childId = String(data: dirBytes, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        {
            return VaultNode(
                cleartextName: clear,
                kind: .directory,
                cipherName: cipherName,
                parentDirId: parentDirId,
                dirId: childId,
                ciphertextKey: folderPrefix + "dir.c9r",
                size: nil,
                eTag: nil
            )
        }
        if (try? await store.getObject(key: folderPrefix + "symlink.c9r")) != nil {
            return VaultNode(
                cleartextName: clear,
                kind: .symlink,
                cipherName: cipherName,
                parentDirId: parentDirId,
                dirId: nil,
                ciphertextKey: folderPrefix + "symlink.c9r",
                size: nil,
                eTag: nil
            )
        }
        return nil
    }

    private func nodeForShortened(cipherName: String, parentDirId: String, folderPrefix: String) async throws -> VaultNode? {
        let nameBytes: Data
        do {
            nameBytes = try await store.getObject(key: folderPrefix + "name.c9s")
        } catch {
            return nil
        }
        let longName = String(data: nameBytes, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cipherBare: String
        if longName.hasSuffix(".c9r") {
            cipherBare = String(longName.dropLast(4))
        } else {
            cipherBare = longName
        }
        let clear: String
        do {
            clear = try cryptor.decryptFileName(cipherBare, dirId: Data(parentDirId.utf8))
        } catch {
            return nil
        }
        if let dirBytes = try? await store.getObject(key: folderPrefix + "dir.c9r"),
           let childId = String(data: dirBytes, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        {
            return VaultNode(
                cleartextName: clear,
                kind: .directory,
                cipherName: cipherName,
                parentDirId: parentDirId,
                dirId: childId,
                ciphertextKey: folderPrefix + "dir.c9r",
                size: nil,
                eTag: nil
            )
        }
        let contentsKey = folderPrefix + "contents.c9r"
        if let meta = try? await store.headObject(key: contentsKey) {
            return VaultNode(
                cleartextName: clear,
                kind: .file,
                cipherName: cipherName,
                parentDirId: parentDirId,
                dirId: nil,
                ciphertextKey: contentsKey,
                size: meta.size,
                eTag: meta.eTag
            )
        }
        if (try? await store.getObject(key: folderPrefix + "symlink.c9r")) != nil {
            return VaultNode(
                cleartextName: clear,
                kind: .symlink,
                cipherName: cipherName,
                parentDirId: parentDirId,
                dirId: nil,
                ciphertextKey: folderPrefix + "symlink.c9r",
                size: nil,
                eTag: nil
            )
        }
        return nil
    }

    private func relativeName(_ key: String, prefix: String) -> String {
        if key.hasPrefix(prefix) {
            return String(key.dropFirst(prefix.count))
        }
        return key
    }

    private func normalized(_ path: String) -> String {
        if path.isEmpty || path == "/" {
            return "/"
        }
        var p = path
        if !p.hasPrefix("/") {
            p = "/" + p
        }
        if p.count > 1, p.hasSuffix("/") {
            p.removeLast()
        }
        return p
    }

    private func split(_ path: String) -> [String] {
        normalized(path).split(separator: "/").map(String.init)
    }
}
