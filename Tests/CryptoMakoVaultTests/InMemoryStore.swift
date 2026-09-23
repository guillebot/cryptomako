import CryptoMakoS3
import XCTest

final class InMemoryStore: ObjectStore, @unchecked Sendable {
    var objects: [String: Data]

    init(objects: [String: Data]) {
        self.objects = objects
    }

    func getObject(key: String) async throws -> Data {
        guard let data = objects[key] else {
            throw ObjectStoreError.notFound(key)
        }
        return data
    }

    func getObject(key: String, to fileURL: URL) async throws {
        let data = try await getObject(key: key)
        try data.write(to: fileURL, options: .atomic)
    }

    func listImmediate(prefix: String) async throws -> PrefixListing {
        var objects: [ListedObject] = []
        var prefixes = Set<String>()
        for (key, data) in self.objects {
            guard key.hasPrefix(prefix) else { continue }
            let rest = String(key.dropFirst(prefix.count))
            if rest.isEmpty { continue }
            if let slash = rest.firstIndex(of: "/") {
                let folder = String(rest[..<slash])
                prefixes.insert(prefix + folder + "/")
            } else {
                objects.append(ListedObject(key: key, size: Int64(data.count), eTag: "etag"))
            }
        }
        return PrefixListing(objects: objects, commonPrefixes: prefixes.sorted())
    }

    func putObject(key: String, data: Data) async throws {
        objects[key] = data
    }

    func deleteObject(key: String) async throws {
        guard objects.removeValue(forKey: key) != nil else {
            throw ObjectStoreError.notFound(key)
        }
    }
}
