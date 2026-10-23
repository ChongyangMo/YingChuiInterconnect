import Foundation

struct MacPublishedReleaseVerifier: Sendable {
    let transport: any AccountHTTPTransport

    func check(_ target: MacAutomaticUpdateTarget, currentBuild: String) async throws {
        try target.validate(currentBuild: currentBuild)
        var request = URLRequest(url: target.release.appcast_url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("application/rss+xml, application/xml", forHTTPHeaderField: "Accept")
        let (data, response) = try await transport.send(request)
        try Task.checkCancellation()
        if response.statusCode == 410 { throw MacManagementError.releaseWithdrawn }
        guard response.statusCode == 200 else { throw MacManagementError.http(response.statusCode) }
        guard response.url == request.url, !data.isEmpty, data.count <= 65_536,
              ["application/rss+xml", "application/xml", "text/xml"].contains(response.mimeType) else {
            throw MacManagementError.response
        }
        try MacFixedReleaseParser.validate(data, target: target)
    }
}

private final class MacFixedReleaseParser: NSObject, XMLParserDelegate {
    var itemCount = 0
    var insideItem = false
    var text = ""
    var fields: [String: String] = [:]
    var enclosure: [String: String]?
    var invalid = false
    var root = ""

    static func validate(_ data: Data, target: MacAutomaticUpdateTarget) throws {
        let reader = MacFixedReleaseParser()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        guard parser.parse(), !reader.invalid, reader.root == "rss", reader.itemCount == 1,
              let enclosure = reader.enclosure,
              reader.fields["sparkle:version"] == target.release.app_build,
              reader.fields["sparkle:shortVersionString"] == target.release.app_version,
              enclosure["url"] == target.artifactURL.absoluteString,
              enclosure["length"].flatMap(UInt64.init) == target.size,
              let signature = enclosure["sparkle:edSignature"],
              Data(base64Encoded: signature)?.count == 64,
              let minimum = reader.fields["sparkle:minimumSystemVersion"],
              MacBuildNumber.isAtLeast(MacUpdateSourcePolicy.osVersion, minimum) else {
            throw MacManagementError.response
        }
        if let maximum = reader.fields["sparkle:maximumSystemVersion"],
           !MacBuildNumber.isAtLeast(maximum, MacUpdateSourcePolicy.osVersion) {
            throw MacManagementError.response
        }
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String]) {
        if root.isEmpty { root = name }
        text = ""
        if name == "item" { itemCount += 1; insideItem = true }
        if insideItem, name == "enclosure" {
            if enclosure != nil { invalid = true }
            enclosure = attributes
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if insideItem, name.hasPrefix("sparkle:") {
            if fields[name] != nil { invalid = true }
            fields[name] = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if name == "item" { insideItem = false }
        text = ""
    }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String,
                publicID: String?, systemID: String?) { invalid = true; parser.abortParsing() }
}
