import Foundation

/// Parses an S3 `ListObjectsV2` XML response.
final class ListObjectsParser: NSObject, XMLParserDelegate {
    private var objects: [ListedObject] = []
    private var commonPrefixes: [String] = []
    private var nextToken: String?
    private var isTruncated = false

    private var element = ""
    private var text = ""
    private var inContents = false
    private var inCommonPrefixes = false
    private var key = ""
    private var size: Int64 = 0
    private var eTag: String?

    struct Result {
        var listing: PrefixListing
        var nextContinuationToken: String?
        var isTruncated: Bool
    }

    static func parse(_ data: Data) throws -> Result {
        let delegate = ListObjectsParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw ObjectStoreError.transport("malformed ListObjectsV2 response")
        }
        return Result(
            listing: PrefixListing(objects: delegate.objects, commonPrefixes: delegate.commonPrefixes),
            nextContinuationToken: delegate.nextToken,
            isTruncated: delegate.isTruncated
        )
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String] = [:]
    ) {
        element = elementName
        text = ""
        switch elementName {
        case "Contents":
            inContents = true
            key = ""
            size = 0
            eTag = nil
        case "CommonPrefixes":
            inCommonPrefixes = true
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "Key" where inContents:
            key = value
        case "Size" where inContents:
            size = Int64(value) ?? 0
        case "ETag" where inContents:
            eTag = value.replacingOccurrences(of: "\"", with: "")
        case "Contents":
            inContents = false
            if !key.isEmpty {
                objects.append(ListedObject(key: key, size: size, eTag: eTag))
            }
        // `Prefix` appears both at the top level and inside `CommonPrefixes`.
        case "Prefix" where inCommonPrefixes:
            if !value.isEmpty {
                commonPrefixes.append(value)
            }
        case "CommonPrefixes":
            inCommonPrefixes = false
        case "NextContinuationToken":
            nextToken = value.isEmpty ? nil : value
        case "IsTruncated":
            isTruncated = (value == "true")
        default:
            break
        }
        text = ""
    }
}
