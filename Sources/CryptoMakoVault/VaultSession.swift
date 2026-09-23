import CryptomatorCryptoLib
import Foundation
import CryptoMakoS3

public final class VaultSession: @unchecked Sendable {
    public let location: VaultLocation
    public let config: VaultConfig
    public let cryptor: Cryptor
    public let rootCipherPrefix: String

    let store: any ObjectStore
    /// Kept so Backup Sync can mint per-task Cryptors and encrypt in parallel.
    private let masterkey: Masterkey
    private let scheme: CryptorScheme
    /// Shared `cryptor` is not documented as concurrent-safe. Serialize name/dir-id
    /// ops on it; content encrypt uses `makeWorkerCryptor()` off this lock.
    private let cryptorLock = NSLock()

    public init(
        location: VaultLocation,
        config: VaultConfig,
        cryptor: Cryptor,
        masterkey: Masterkey,
        scheme: CryptorScheme,
        store: any ObjectStore
    ) throws {
        self.location = location
        self.config = config
        self.cryptor = cryptor
        self.masterkey = masterkey
        self.scheme = scheme
        self.store = store
        self.rootCipherPrefix = try DirLayout.ciphertextDirectoryPrefix(
            prefix: location.prefix,
            cryptor: cryptor,
            dirId: ""
        )
    }

    /// Run a section on the shared cryptor exclusively (names / dir-id hashing).
    func withCryptor<T>(_ body: () throws -> T) rethrows -> T {
        cryptorLock.lock()
        defer { cryptorLock.unlock() }
        return try body()
    }

    /// Private Cryptor for parallel content encrypt/decrypt (own Masterkey copy).
    func makeWorkerCryptor() -> Cryptor {
        let mk = Masterkey.createFromRaw(rawKey: masterkey.rawKey)
        return Cryptor(masterkey: mk, scheme: scheme)
    }

    /// Concurrent GCD queue for blocking `encryptContent` so Sync tasks do not
    /// saturate Swift's cooperative thread pool (that starvation collapsed
    /// URLSession PUT concurrency to ~1 and left the uplink at ~1 Mbps).
    private static let contentEncryptQueue = DispatchQueue(
        label: "net.gschimmel.cryptomako.content-encrypt",
        qos: .userInitiated,
        attributes: .concurrent
    )

    /// Encrypt cleartext→ciphertext off the cooperative pool.
    func encryptContentOffPool(from clearURL: URL, to cipherURL: URL) async throws {
        let worker = makeWorkerCryptor()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            Self.contentEncryptQueue.async {
                do {
                    try worker.encryptContent(from: clearURL, to: cipherURL)
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
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
        return try VaultSession(location: location, config: config, cryptor: cryptor, masterkey: masterkey, scheme: scheme, store: store)
    }


    /// Cleartext **file** names only (no `dir.c9r` / symlink GETs).
    /// Backup Sync bootstrap-skip used full `list`, which for every subdirectory
    /// issued a serial GET — that prep phase never reached puts and left the
    /// uplink near idle while Sync said "running".
    public func listFileNames(dirId: String = "") async throws -> Set<String> {
        let dirPrefix = try withCryptor {
            try DirLayout.ciphertextDirectoryPrefix(
                prefix: location.prefix,
                cryptor: cryptor,
                dirId: dirId
            )
        }
        let listing = try await store.listImmediate(prefix: dirPrefix)
        var names = Set<String>()
        for object in listing.objects {
            let name = relativeName(object.key, prefix: dirPrefix)
            guard !name.contains("/"), !name.isEmpty, name != "dirid.c9r" else { continue }
            guard name.hasSuffix(".c9r") else { continue }
            let cipherBare = String(name.dropLast(4))
            guard let clear = try? withCryptor({
                try cryptor.decryptFileName(cipherBare, dirId: Data(dirId.utf8))
            }) else { continue }
            names.insert(clear)
        }
        // Shortened files live under `.c9s/` prefixes; one name.c9s GET each.
        // Rare vs full-tree dir.c9r fan-out — only resolve when present.
        for common in listing.commonPrefixes {
            let folderName = relativeName(common, prefix: dirPrefix)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard folderName.hasSuffix(".c9s") else { continue }
            let folderPrefix = common.hasSuffix("/") ? common : common + "/"
            guard let nameBytes = try? await store.getObject(key: folderPrefix + "name.c9s") else { continue }
            let longName = String(data: nameBytes, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let cipherBare = longName.hasSuffix(".c9r") ? String(longName.dropLast(4)) : longName
            // Only count as a file if contents exist (dirs also use .c9s).
            guard (try? await store.headObject(key: folderPrefix + "contents.c9r")) != nil else { continue }
            guard let clear = try? withCryptor({
                try cryptor.decryptFileName(cipherBare, dirId: Data(dirId.utf8))
            }) else { continue }
            names.insert(clear)
        }
        return names
    }

    /// O(1) lookup: encrypt expected cipher name and GET `dir.c9r` (no full LIST).
    public func existingDirectoryId(parentDirId: String, cleartextName: String) async throws -> String? {
        let name = cleartextName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/") else { return nil }
        let dirMarkerKey: String = try withCryptor {
            let encName = try cryptor.encryptFileName(name, dirId: Data(parentDirId.utf8)) + ".c9r"
            let parentPrefix = try DirLayout.ciphertextDirectoryPrefix(
                prefix: location.prefix,
                cryptor: cryptor,
                dirId: parentDirId
            )
            let display = encName.count > config.shorteningThreshold
                ? DirLayout.shortenedName(ciphertextFileName: encName)
                : encName
            return parentPrefix + display + "/dir.c9r"
        }
        do {
            let data = try await store.getObject(key: dirMarkerKey)
            let id = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return id.isEmpty ? nil : id
        } catch ObjectStoreError.notFound {
            return nil
        }
    }

    public func list(dirId: String = "") async throws -> [VaultNode] {
        let dirPrefix = try withCryptor {
            try DirLayout.ciphertextDirectoryPrefix(
                prefix: location.prefix,
                cryptor: cryptor,
                dirId: dirId
            )
        }
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

    public func listRecursive(at cleartextPath: String = "/", maxEntries: Int = 5_000) async throws -> [(String, VaultNode)] {
        var results: [(String, VaultNode)] = []
        results.reserveCapacity(min(maxEntries, 256))

        let startPath = normalized(cleartextPath)
        let startDirId: String
        if startPath == "/" {
            startDirId = ""
        } else {
            let node = try await resolve(cleartextPath: startPath)
            guard node.kind == .directory, let child = node.dirId else {
                throw VaultError.notAFile(startPath)
            }
            startDirId = child
        }

        // Explicit-stack DFS matches the previous recursive order without a
        // call-stack overflow on deep trees, and respects maxEntries.
        let rootNodes = try await list(dirId: startDirId)
        var stack: [(dirId: String, path: String, nodes: [VaultNode], index: Int)] = [
            (startDirId, startPath, rootNodes, 0),
        ]
        while !stack.isEmpty {
            let top = stack.count - 1
            if stack[top].index >= stack[top].nodes.count {
                stack.removeLast()
                continue
            }
            let node = stack[top].nodes[stack[top].index]
            stack[top].index += 1

            if results.count >= maxEntries {
                return results
            }
            let parentPath = stack[top].path
            let childPath = parentPath == "/" ? "/\(node.cleartextName)" : "\(parentPath)/\(node.cleartextName)"
            results.append((childPath, node))
            if node.kind == .directory, let childId = node.dirId {
                let childNodes = try await list(dirId: childId)
                stack.append((childId, childPath, childNodes, 0))
            }
        }
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
        try withCryptor { try cryptor.decryptContent(from: cipherURL, to: destination) }
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

    private func nodeForFileObject(name: String, parentDirId: String, object: ListedObject) async throws -> VaultNode? {
        let cipherBare = String(name.dropLast(4)) // strip .c9r
        let clear: String
        do {
            clear = try withCryptor { try cryptor.decryptFileName(cipherBare, dirId: Data(parentDirId.utf8)) }
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
            clear = try withCryptor { try cryptor.decryptFileName(cipherBare, dirId: Data(parentDirId.utf8)) }
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
            clear = try withCryptor { try cryptor.decryptFileName(cipherBare, dirId: Data(parentDirId.utf8)) }
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
