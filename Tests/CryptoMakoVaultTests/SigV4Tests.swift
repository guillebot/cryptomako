import XCTest

@testable import CryptoMakoS3

/// Vectors published by AWS in the "Signature Calculations for the Authorization
/// Header" examples (bucket `examplebucket`, 2013-05-24).
final class SigV4Tests: XCTestCase {
    private let credentials = SigV4.Credentials(
        accessKey: "AKIAIOSFODNN7EXAMPLE",
        secretKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
        region: "us-east-1"
    )

    private var referenceDate: Date {
        var components = DateComponents()
        components.year = 2013
        components.month = 5
        components.day = 24
        components.hour = 0
        components.minute = 0
        components.second = 0
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: components)!
    }

    private func signature(for url: String) -> String {
        let request = URLRequest(url: URL(string: url)!)
        let headers = SigV4.sign(
            request: request,
            credentials: credentials,
            now: referenceDate
        )
        let auth = headers["Authorization"] ?? ""
        guard let range = auth.range(of: "Signature=") else { return "" }
        return String(auth[range.upperBound...])
    }

    func testGetBucketLifecycleVector() {
        XCTAssertEqual(
            signature(for: "https://examplebucket.s3.amazonaws.com/?lifecycle="),
            "fea454ca298b7da1c68078a5d1bdbfbbe0d65c699e0f91ac7a200a0136783543"
        )
    }

    func testListObjectsVectorSortsQuery() {
        XCTAssertEqual(
            signature(for: "https://examplebucket.s3.amazonaws.com/?max-keys=2&prefix=J"),
            "34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7"
        )
    }

    func testAuthorizationHeaderShape() {
        let request = URLRequest(url: URL(string: "https://examplebucket.s3.amazonaws.com/?lifecycle=")!)
        let headers = SigV4.sign(request: request, credentials: credentials, now: referenceDate)
        XCTAssertEqual(headers["x-amz-date"], "20130524T000000Z")
        XCTAssertEqual(headers["x-amz-content-sha256"], SigV4.emptyPayloadSHA256)
        XCTAssertEqual(headers["host"], "examplebucket.s3.amazonaws.com")
        let auth = headers["Authorization"] ?? ""
        XCTAssertTrue(auth.hasPrefix("AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request"))
        XCTAssertTrue(auth.contains("SignedHeaders=host;x-amz-content-sha256;x-amz-date"))
    }

    func testHostHeaderKeepsNonDefaultPort() {
        let request = URLRequest(url: URL(string: "http://minio.example.net:9000/bucket/key")!)
        let headers = SigV4.sign(request: request, credentials: credentials, now: referenceDate)
        XCTAssertEqual(headers["host"], "minio.example.net:9000")
    }

    func testCanonicalPathKeepsTrailingSlash() {
        // URL.path drops this; ListObjectsV2 signs /bucket/ and fails without it.
        let url = URL(string: "http://minio.example.net:9000/bucket/?list-type=2")!
        XCTAssertEqual(SigV4.canonicalPath(url), "/bucket/")
    }

    func testCanonicalPathEncodesUnicodeSegments() {
        let url = URL(string: "http://minio.example.net:9000/bucket/caf%C3%A9%20r.txt")!
        XCTAssertEqual(SigV4.canonicalPath(url), "/bucket/caf%C3%A9%20r.txt")
    }

    func testUriEncodePreservesSlashInPathOnly() {
        XCTAssertEqual(SigV4.uriEncode("a/b c", encodeSlash: false), "a/b%20c")
        XCTAssertEqual(SigV4.uriEncode("a/b c", encodeSlash: true), "a%2Fb%20c")
        XCTAssertEqual(SigV4.uriEncode("café", encodeSlash: false), "caf%C3%A9")
        XCTAssertEqual(SigV4.uriEncode("-._~", encodeSlash: false), "-._~")
    }

    func testListObjectsParserReadsContentsAndPrefixes() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult>
          <Name>sch-backup</Name>
          <Prefix>cryptomako-poc/</Prefix>
          <IsTruncated>false</IsTruncated>
          <Contents>
            <Key>cryptomako-poc/vault.cryptomator</Key>
            <Size>283</Size>
            <ETag>"abc123"</ETag>
          </Contents>
          <CommonPrefixes><Prefix>cryptomako-poc/d/</Prefix></CommonPrefixes>
        </ListBucketResult>
        """
        let result = try ListObjectsParser.parse(Data(xml.utf8))
        XCTAssertEqual(result.listing.objects.count, 1)
        XCTAssertEqual(result.listing.objects[0].key, "cryptomako-poc/vault.cryptomator")
        XCTAssertEqual(result.listing.objects[0].size, 283)
        XCTAssertEqual(result.listing.objects[0].eTag, "abc123")
        // The top-level <Prefix> must not be mistaken for a common prefix.
        XCTAssertEqual(result.listing.commonPrefixes, ["cryptomako-poc/d/"])
        XCTAssertFalse(result.isTruncated)
    }

    func testListObjectsParserRejectsMalformedXML() {
        XCTAssertThrowsError(try ListObjectsParser.parse(Data("<not-closed".utf8)))
    }

    func testListObjectsParserCollectsMultipleContents() throws {
        let xml = """
        <ListBucketResult>
          <Contents><Key>a</Key><Size>1</Size></Contents>
          <Contents><Key>b</Key><Size>2</Size><ETag>"x"</ETag></Contents>
          <CommonPrefixes><Prefix>p/</Prefix></CommonPrefixes>
        </ListBucketResult>
        """
        let result = try ListObjectsParser.parse(Data(xml.utf8))
        XCTAssertEqual(result.listing.objects.map(\.key), ["a", "b"])
        XCTAssertEqual(result.listing.commonPrefixes, ["p/"])
    }
}
