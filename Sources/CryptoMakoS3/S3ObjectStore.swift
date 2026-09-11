import Foundation
import SotoS3

public struct S3Settings: Sendable {
    public var endpoint: URL
    public var region: String
    public var bucket: String
    public var accessKey: String
    public var secretKey: String
    public var pathStyle: Bool

    public init(
        endpoint: URL,
        region: String,
        bucket: String,
        accessKey: String,
        secretKey: String,
        pathStyle: Bool = true
    ) {
        self.endpoint = endpoint
        self.region = region
        self.bucket = bucket
        self.accessKey = accessKey
        self.secretKey = secretKey
        self.pathStyle = pathStyle
    }
}

public final class S3ObjectStore: ObjectStore, @unchecked Sendable {
    private let client: AWSClient
    private let s3: S3
    private let bucket: String

    public init(settings: S3Settings) {
        self.bucket = settings.bucket
        let region = Region(awsRegionName: settings.region)
        self.client = AWSClient(
            credentialProvider: .static(
                accessKeyId: settings.accessKey,
                secretAccessKey: settings.secretKey
            )
        )
        var options: AWSServiceConfig.Options = []
        if settings.pathStyle {
            options.insert(.s3UsePathStyleAddressing)
        }
        self.s3 = S3(
            client: client,
            region: region,
            endpoint: settings.endpoint.absoluteString,
            timeout: .seconds(60),
            options: options
        )
    }

    public func shutdown() async throws {
        try await client.shutdown()
    }

    public func getObject(key: String) async throws -> Data {
        do {
            let response = try await s3.getObject(.init(bucket: bucket, key: key))
            guard let body = response.body else {
                return Data()
            }
            return try await collect(body)
        } catch let error as S3ErrorType where error == .noSuchKey {
            throw ObjectStoreError.notFound(key)
        } catch {
            if isMissing(error) {
                throw ObjectStoreError.notFound(key)
            }
            throw ObjectStoreError.transport(String(describing: error))
        }
    }

    public func getObject(key: String, to fileURL: URL) async throws {
        let data = try await getObject(key: key)
        try data.write(to: fileURL, options: .atomic)
    }

    public func listImmediate(prefix: String) async throws -> PrefixListing {
        var objects: [ListedObject] = []
        var prefixes: [String] = []
        var token: String?
        repeat {
            let output: S3.ListObjectsV2Output
            do {
                output = try await s3.listObjectsV2(
                    .init(
                        bucket: bucket,
                        continuationToken: token,
                        delimiter: "/",
                        maxKeys: 1000,
                        prefix: prefix
                    )
                )
            } catch {
                throw ObjectStoreError.transport(String(describing: error))
            }
            for obj in output.contents ?? [] {
                guard let key = obj.key else { continue }
                objects.append(
                    ListedObject(
                        key: key,
                        size: obj.size ?? 0,
                        eTag: obj.eTag
                    )
                )
            }
            for p in output.commonPrefixes ?? [] {
                if let pref = p.prefix {
                    prefixes.append(pref)
                }
            }
            token = output.nextContinuationToken
            if output.isTruncated != true {
                break
            }
        } while token != nil
        return PrefixListing(objects: objects, commonPrefixes: prefixes)
    }

    private func collect(_ body: AWSHTTPBody) async throws -> Data {
        let buffer = try await body.collect(upTo: 64 * 1024 * 1024)
        return Data(buffer.readableBytesView)
    }

    private func isMissing(_ error: Error) -> Bool {
        let text = String(describing: error)
        return text.contains("NoSuchKey") || text.contains("NotFound") || text.contains("404")
    }
}
