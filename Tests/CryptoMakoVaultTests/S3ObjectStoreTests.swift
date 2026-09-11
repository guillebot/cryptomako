import CryptoMakoS3
import XCTest

final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class S3ObjectStoreTests: XCTestCase {
    private var session: URLSession!
    private var store: S3ObjectStore!

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: config)
        store = S3ObjectStore(
            settings: S3Settings(
                endpoint: URL(string: "http://127.0.0.1:9000")!,
                region: "us-east-1",
                bucket: "cryptomako-poc",
                accessKey: "cryptomako",
                secretKey: "cryptomako-minio-dev",
                pathStyle: true
            ),
            session: session
        )
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    func testGetObjectReturnsBodyOn200() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertTrue(request.url?.path.contains("/cryptomako-poc/family/hello.txt") == true)
            XCTAssertNotNil(request.value(forHTTPHeaderField: "Authorization"))
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": "5"]
            )!
            return (response, Data("hello".utf8))
        }
        let data = try await store.getObject(key: "family/hello.txt")
        XCTAssertEqual(String(data: data, encoding: .utf8), "hello")
    }

    func testGetObjectMaps404ToNotFound() async {
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        do {
            _ = try await store.getObject(key: "missing/key")
            XCTFail("expected notFound")
        } catch ObjectStoreError.notFound(let key) {
            XCTAssertEqual(key, "missing/key")
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testListImmediatePaginatesWithContinuationToken() async throws {
        var callCount = 0
        MockURLProtocol.handler = { request in
            callCount += 1
            let xml: String
            if callCount == 1 {
                xml = """
                <ListBucketResult>
                  <IsTruncated>true</IsTruncated>
                  <NextContinuationToken>page2</NextContinuationToken>
                  <Contents><Key>cryptomako-poc/a</Key><Size>1</Size></Contents>
                </ListBucketResult>
                """
            } else {
                XCTAssertTrue(request.url?.query?.contains("continuation-token=page2") == true)
                xml = """
                <ListBucketResult>
                  <IsTruncated>false</IsTruncated>
                  <Contents><Key>cryptomako-poc/b</Key><Size>2</Size></Contents>
                </ListBucketResult>
                """
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(xml.utf8))
        }
        let listing = try await store.listImmediate(prefix: "cryptomako-poc/")
        XCTAssertEqual(listing.objects.map(\.key), ["cryptomako-poc/a", "cryptomako-poc/b"])
        XCTAssertEqual(callCount, 2)
    }

    func testHeadObjectReadsContentLength() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "HEAD")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "Content-Length": "42",
                    "ETag": "\"abc\"",
                ]
            )!
            return (response, Data())
        }
        let meta = try await store.headObject(key: "family/file.c9r")
        XCTAssertEqual(meta.size, 42)
        XCTAssertEqual(meta.eTag, "abc")
    }
}
