import CryptoMakoVault
import Foundation

/// Cleartext vault filesystem for backup/sync tools (rclone).
/// Implements CryptoMakoVaultFS (ObjC protocol); GM* types stay in CryptoMakoFuseHost.m.
final class VaultFuseDelegate: NSObject, CryptoMakoVaultFS {
    private let bridge: VaultFuseBridge
    private let openFiles = NSLock()
    private var states: [ObjectIdentifier: OpenState] = [:]

    init(bridge: VaultFuseBridge) {
        self.bridge = bridge
        super.init()
    }

    func listDirectory(atPath path: String) throws -> [[AnyHashable: Any]] {
        let dirId = try resolveDirId(path)
        let nodes = try bridge.call { try await $0.list(dirId: dirId) }
        return nodes.map { node in
            [
                "name": node.cleartextName,
                "attributes": Self.attrs(for: node),
            ]
        }
    }

    func attributesOfFileSystem(forPath path: String) throws -> [AnyHashable: Any] {
        [
            FileAttributeKey.systemSize: NSNumber(value: Int64(8) * 1024 * 1024 * 1024 * 1024),
            FileAttributeKey.systemFreeSize: NSNumber(value: Int64(4) * 1024 * 1024 * 1024 * 1024),
            FileAttributeKey.systemNodes: NSNumber(value: 1_000_000),
            FileAttributeKey.systemFreeNodes: NSNumber(value: 999_000),
        ]
    }

    func attributesOfItem(atPath path: String, userData: Any?) throws -> [AnyHashable: Any] {
        if let state = userData as? OpenState {
            return [
                FileAttributeKey.type: FileAttributeType.typeRegular,
                FileAttributeKey.size: NSNumber(value: state.size),
                FileAttributeKey.posixPermissions: NSNumber(value: 0o644),
            ]
        }
        if isRoot(path) {
            return [
                FileAttributeKey.type: FileAttributeType.typeDirectory,
                FileAttributeKey.posixPermissions: NSNumber(value: 0o755),
                FileAttributeKey.referenceCount: NSNumber(value: 2),
            ]
        }
        if let node = try findNode(path) {
            return Self.attrs(for: node)
        }
        throw posix(ENOENT)
    }

    func createDirectory(atPath path: String, attributes: [AnyHashable: Any] = [:]) throws {
        let (parentPath, name) = split(path)
        let parentId = try resolveDirId(parentPath)
        _ = try bridge.call {
            try await $0.createDirectory(parentDirId: parentId, cleartextName: name)
        }
    }

    func removeDirectory(atPath path: String) throws {
        guard let node = try findNode(path), node.kind == .directory else { throw posix(ENOENT) }
        try bridge.call { try await $0.deleteDirectory(node: node, recursive: false) }
    }

    func removeItem(atPath path: String) throws {
        guard let node = try findNode(path) else { throw posix(ENOENT) }
        try bridge.call { try await $0.deleteNode(node, recursive: true) }
    }

    func createFile(
        atPath path: String,
        attributes: [AnyHashable: Any],
        flags: Int32,
        userData: AutoreleasingUnsafeMutablePointer<AnyObject?>
    ) throws {
        let state = try OpenState.makeEmpty(path: path)
        state.dirty = true
        state.isNew = true
        track(state)
        userData.pointee = state
    }

    func openFile(
        atPath path: String,
        mode: Int32,
        userData: AutoreleasingUnsafeMutablePointer<AnyObject?>
    ) throws {
        guard let node = try findNode(path), node.kind != .directory else { throw posix(ENOENT) }
        let state = try OpenState.makeFromRemote(path: path, node: node, bridge: bridge)
        track(state)
        userData.pointee = state
    }

    func releaseFile(atPath path: String, userData: Any?) {
        guard let state = userData as? OpenState else { return }
        defer {
            untrack(state)
            try? FileManager.default.removeItem(at: state.tempURL)
        }
        do { try commitIfNeeded(state) }
        catch { NSLog("CryptoMako FUSE flush failed for %@: %@", path, error.localizedDescription) }
    }

    func readFile(
        atPath path: String,
        userData: Any?,
        buffer: UnsafeMutablePointer<CChar>,
        size: Int,
        offset: off_t,
        error outError: NSErrorPointer
    ) -> Int32 {
        do {
            guard let state = userData as? OpenState else { throw posix(EBADF) }
            let handle = try FileHandle(forReadingFrom: state.tempURL)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(max(0, offset)))
            let data = try handle.read(upToCount: size) ?? Data()
            data.copyBytes(to: UnsafeMutableRawPointer(buffer).assumingMemoryBound(to: UInt8.self), count: data.count)
            return Int32(data.count)
        } catch let err as NSError {
            outError?.pointee = err
            return -1
        } catch let err {
            outError?.pointee = err as NSError
            return -1
        }
    }

    func writeFile(
        atPath path: String,
        userData: Any?,
        buffer: UnsafePointer<CChar>,
        size: Int,
        offset: off_t,
        error outError: NSErrorPointer
    ) -> Int32 {
        do {
            guard let state = userData as? OpenState else { throw posix(EBADF) }
            let handle = try FileHandle(forWritingTo: state.tempURL)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(max(0, offset)))
            try handle.write(contentsOf: Data(bytes: buffer, count: size))
            state.dirty = true
            state.size = max(state.size, Int64(offset) + Int64(size))
            return Int32(size)
        } catch let err as NSError {
            outError?.pointee = err
            return -1
        } catch let err {
            outError?.pointee = err as NSError
            return -1
        }
    }

    func setAttributes(
        _ attributes: [AnyHashable: Any],
        ofItemAtPath path: String,
        userData: Any?
    ) throws {
        if let state = userData as? OpenState {
            if let sizeNum = attributes[FileAttributeKey.size] as? NSNumber
                ?? attributes["NSFileSize"] as? NSNumber {
                let handle = try FileHandle(forWritingTo: state.tempURL)
                defer { try? handle.close() }
                try handle.truncate(atOffset: sizeNum.uint64Value)
                state.size = sizeNum.int64Value
                state.dirty = true
            }
            try commitIfNeeded(state)
        }
    }

    private func commitIfNeeded(_ state: OpenState) throws {
        guard state.dirty else { return }
        let (parentPath, name) = split(state.path)
        let parentId = try resolveDirId(parentPath)
        _ = try bridge.call {
            try await $0.createOrOverwriteFile(
                parentDirId: parentId,
                cleartextName: name,
                contentsURL: state.tempURL
            )
        }
        state.dirty = false
    }

    private func isRoot(_ path: String) -> Bool { path == "/" || path.isEmpty }

    private func split(_ path: String) -> (parent: String, name: String) {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let parts = trimmed.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        guard let name = parts.last else { return ("/", "") }
        if parts.count == 1 { return ("/", name) }
        return ("/" + parts.dropLast().joined(separator: "/"), name)
    }

    private func resolveDirId(_ path: String) throws -> String {
        if isRoot(path) { return "" }
        guard let node = try findNode(path), node.kind == .directory, let id = node.dirId else {
            throw posix(ENOENT)
        }
        return id
    }

    private func findNode(_ path: String) throws -> VaultNode? {
        if isRoot(path) { return nil }
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        do {
            return try bridge.call { try await $0.resolve(cleartextPath: "/" + trimmed) }
        } catch {
            return nil
        }
    }

    private static func attrs(for node: VaultNode) -> [FileAttributeKey: Any] {
        switch node.kind {
        case .directory:
            return [
                .type: FileAttributeType.typeDirectory,
                .posixPermissions: NSNumber(value: 0o755),
                .referenceCount: NSNumber(value: 2),
            ]
        case .file, .symlink:
            return [
                .type: FileAttributeType.typeRegular,
                .size: NSNumber(value: node.size ?? 0),
                .posixPermissions: NSNumber(value: 0o644),
                .referenceCount: NSNumber(value: 1),
            ]
        }
    }

    private func posix(_ code: Int32) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: nil)
    }

    private func track(_ state: OpenState) {
        openFiles.lock(); states[ObjectIdentifier(state)] = state; openFiles.unlock()
    }

    private func untrack(_ state: OpenState) {
        openFiles.lock(); states.removeValue(forKey: ObjectIdentifier(state)); openFiles.unlock()
    }
}

final class OpenState: NSObject {
    let path: String
    let tempURL: URL
    var dirty: Bool = false
    var isNew: Bool = false
    var size: Int64 = 0

    private init(path: String, tempURL: URL, size: Int64) {
        self.path = path
        self.tempURL = tempURL
        self.size = size
    }

    static func makeEmpty(path: String) throws -> OpenState {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fuse-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: url.path, contents: Data(), attributes: nil)
        return OpenState(path: path, tempURL: url, size: 0)
    }

    static func makeFromRemote(path: String, node: VaultNode, bridge: VaultFuseBridge) throws -> OpenState {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fuse-\(UUID().uuidString)")
        try bridge.call { try await $0.fetch(node: node, to: url) }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? (node.size ?? 0)
        return OpenState(path: path, tempURL: url, size: size)
    }
}
