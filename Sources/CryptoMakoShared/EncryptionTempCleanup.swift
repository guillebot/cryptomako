import Foundation
import OSLog

/// Selection + best-effort removal of orphaned encryption temp files.
///
/// Upload encrypts to
/// `FileManager.default.temporaryDirectory/cryptomako-enc-<UUID>.c9r`
/// (`VaultSession+Writes.createOrOverwriteFile`). A mid-run kill can leave those
/// behind. Cleanup is age-gated so an in-flight encrypt (this process or another)
/// is never deleted.
public enum EncryptionTempCleanup: Sendable {
    /// Matches `VaultSession+Writes` naming: `cryptomako-enc-\(UUID().uuidString).c9r`.
    public static let fileNamePrefix = "cryptomako-enc-"
    public static let fileNameSuffix = ".c9r"
    /// Conservative: only reclaim temps older than this. Live encrypts of large
    /// files can run for a long time; a few hours avoids racing them.
    public static let minAge: TimeInterval = 6 * 60 * 60

    private static let log = Logger(subsystem: "net.gschimmel.cryptomako", category: "enc-temp")

    private static let uuidPattern =
        #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#

    /// Pure: whether `name` is exactly this app's encryption temp naming pattern.
    public static func matchesAppPattern(_ name: String) -> Bool {
        guard name.hasPrefix(fileNamePrefix), name.hasSuffix(fileNameSuffix) else {
            return false
        }
        let uuidPart = String(
            name.dropFirst(fileNamePrefix.count).dropLast(fileNameSuffix.count)
        )
        return uuidPart.range(of: uuidPattern, options: .regularExpression) != nil
    }

    /// Pure: which names among `entries` are safe to delete at `now`.
    public static func namesToDelete(
        entries: [(name: String, modificationDate: Date)],
        now: Date,
        minAge: TimeInterval = minAge
    ) -> [String] {
        let cutoff = now.addingTimeInterval(-minAge)
        return entries.compactMap { entry in
            guard matchesAppPattern(entry.name), entry.modificationDate <= cutoff else {
                return nil
            }
            return entry.name
        }
    }

    /// Best-effort filesystem sweep. Never throws; never aborts a backup.
    @discardableResult
    public static func removeStaleOrphans(
        in directory: URL = FileManager.default.temporaryDirectory,
        now: Date = Date(),
        minAge: TimeInterval = minAge,
        fileManager: FileManager = .default
    ) -> Int {
        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            log.error(
                "enc temp list failed path=\(directory.path, privacy: .private(mask: .hash)) error=\(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            return 0
        }

        var entries: [(name: String, modificationDate: Date)] = []
        for url in contents {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            guard values?.isRegularFile == true else { continue }
            let mtime = values?.contentModificationDate ?? .distantPast
            entries.append((url.lastPathComponent, mtime))
        }

        let victims = namesToDelete(entries: entries, now: now, minAge: minAge)
        var removed = 0
        for name in victims {
            let url = directory.appendingPathComponent(name)
            do {
                try fileManager.removeItem(at: url)
                removed += 1
            } catch {
                log.error(
                    "enc temp delete failed name=\(name, privacy: .private(mask: .hash)) error=\(error.localizedDescription, privacy: .private(mask: .hash))"
                )
            }
        }
        if removed > 0 {
            log.info("enc temp cleanup removed=\(removed)")
        }
        return removed
    }
}
