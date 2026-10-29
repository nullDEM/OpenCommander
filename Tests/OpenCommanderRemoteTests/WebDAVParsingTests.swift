import XCTest
@testable import OpenCommanderRemote
@testable import OpenCommanderCore

/// Odpowiedzi 207 kontrolowane przez test (bez serwera): przestrzenie nazw, kodowanie href, brakujące właściwości, błędy per zasób.
final class WebDAVParsingTests: XCTestCase {
    func resolver(_ base: String = "https://dav.example.test/") -> DAVHrefResolver { DAVHrefResolver(baseURL: URL(string: base)!)! }

    func entries(_ xml: String, dir: String = "/", base: String = "https://dav.example.test/") throws -> [RemoteEntry] {
        let items = try DAVMultiStatusParser.parse(Data(xml.utf8))
        return DAVListing.entries(from: items, directory: RemotePath(parsing: dir), resolver: resolver(base)).entries
    }

    func testDifferentNamespacePrefixesAreUnderstood() throws {
        for prefix in ["D", "d", "lp1", "ns0"] {
            let xml = """
            <?xml version="1.0"?><\(prefix):multistatus xmlns:\(prefix)="DAV:">
            <\(prefix):response><\(prefix):href>/</\(prefix):href><\(prefix):propstat><\(prefix):prop><\(prefix):resourcetype><\(prefix):collection/></\(prefix):resourcetype></\(prefix):prop><\(prefix):status>HTTP/1.1 200 OK</\(prefix):status></\(prefix):propstat></\(prefix):response>
            <\(prefix):response><\(prefix):href>/plik.txt</\(prefix):href><\(prefix):propstat><\(prefix):prop><\(prefix):resourcetype/><\(prefix):getcontentlength>12</\(prefix):getcontentlength><\(prefix):getlastmodified>Tue, 14 Oct 2025 10:00:00 GMT</\(prefix):getlastmodified></\(prefix):prop><\(prefix):status>HTTP/1.1 200 OK</\(prefix):status></\(prefix):propstat></\(prefix):response>
            </\(prefix):multistatus>
            """
            let e = try entries(xml)
            XCTAssertEqual(e.map(\.name), ["plik.txt"], "prefiks \(prefix)")
            XCTAssertEqual(e[0].size, 12); XCTAssertEqual(e[0].kind, .file); XCTAssertNotNil(e[0].modified)
        }
    }

    func testElementsInForeignNamespacesAreNotMistakenForDAV() throws {
        let xml = """
        <D:multistatus xmlns:D="DAV:" xmlns:X="urn:other"><D:response><D:href>/a</D:href><D:propstat><D:prop>
        <X:getcontentlength>999</X:getcontentlength><X:collection/><D:resourcetype/></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response></D:multistatus>
        """
        let e = try entries(xml)
        XCTAssertEqual(e.count, 1); XCTAssertEqual(e[0].kind, .file); XCTAssertNil(e[0].size)
    }

    func testEncodedAbsoluteAndRawUnicodeHrefsResolveToSameNames() throws {
        let xml = """
        <D:multistatus xmlns:D="DAV:">
        <D:response><D:href>/dir/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
        <D:response><D:href>/dir/raport%20%231%20%28100%25%29.txt</D:href><D:propstat><D:prop><D:resourcetype/></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
        <D:response><D:href>https://dav.example.test/dir/za%C5%BC%C3%B3%C5%82%C4%87.txt</D:href><D:propstat><D:prop><D:resourcetype/></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
        <D:response><D:href>/dir/surowy zażółć.txt</D:href><D:propstat><D:prop><D:resourcetype/></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
        <D:response><D:href>/dir/a%3Fb%26c.txt</D:href><D:propstat><D:prop><D:resourcetype/></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
        </D:multistatus>
        """
        let names = Set(try entries(xml, dir: "/dir").map(\.name))
        XCTAssertEqual(names, ["raport #1 (100%).txt", "zażółć.txt", "surowy zażółć.txt", "a?b&c.txt"])
    }

    func testTrailingSlashAndSelfEntryAreNormalised() throws {
        let xml = """
        <D:multistatus xmlns:D="DAV:">
        <D:response><D:href>/dir</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
        <D:response><D:href>/dir/pod/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
        </D:multistatus>
        """
        let e = try entries(xml, dir: "/dir/")
        XCTAssertEqual(e.map(\.name), ["pod"]); XCTAssertEqual(e[0].kind, .directory)
    }

    func testBasePathPrefixIsStrippedAndForeignPathsAreIgnored() throws {
        let base = "https://dav.example.test/remote.php/dav/files/ola/"
        let xml = """
        <D:multistatus xmlns:D="DAV:">
        <D:response><D:href>/remote.php/dav/files/ola/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
        <D:response><D:href>/remote.php/dav/files/ola/Dokumenty/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
        <D:response><D:href>/remote.php/dav/files/inny/tajne.txt</D:href><D:propstat><D:prop><D:resourcetype/></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
        <D:response><D:href>/etc/passwd</D:href><D:propstat><D:prop><D:resourcetype/></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
        </D:multistatus>
        """
        XCTAssertEqual(try entries(xml, base: base).map(\.name), ["Dokumenty"])
    }

    func testHostileHrefsAreRejected() throws {
        let r = resolver()
        XCTAssertNil(r.path(forHref: "/a/%2e%2e/etc"))
        XCTAssertNil(r.path(forHref: "/a/..%2Fb"))
        XCTAssertNil(r.path(forHref: "https://evil.example.test/a.txt"), "inny host")
        XCTAssertNil(r.path(forHref: "http://dav.example.test/a.txt"), "inny schemat")
        XCTAssertNil(r.path(forHref: "https://dav.example.test:8443/a.txt"), "inny port")
        XCTAssertNil(r.path(forHref: "/a/\u{0}b"))
        XCTAssertEqual(r.path(forHref: "/ok/plik.txt")?.string, "/ok/plik.txt")
    }

    func testMissingPropertiesDoNotBreakListing() throws {
        let xml = """
        <D:multistatus xmlns:D="DAV:">
        <D:response><D:href>/bez-rozmiaru.bin</D:href><D:propstat><D:prop><D:resourcetype/></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
        <D:response><D:href>/bez-niczego</D:href></D:response>
        <D:response><D:href>/folder-bez-props/</D:href></D:response>
        </D:multistatus>
        """
        let e = try entries(xml)
        XCTAssertEqual(e.count, 3)
        XCTAssertNil(e.first { $0.name == "bez-rozmiaru.bin" }?.size)
        XCTAssertEqual(e.first { $0.name == "folder-bez-props" }?.kind, .directory, "rodzaj odgadnięty po ukośniku")
    }

    func testPerResourceErrorStatusIsToleratedAndPropsFromFailedPropstatAreIgnored() throws {
        let xml = """
        <D:multistatus xmlns:D="DAV:">
        <D:response><D:href>/zablokowany.txt</D:href>
          <D:propstat><D:prop><D:getcontentlength>5</D:getcontentlength></D:prop><D:status>HTTP/1.1 403 Forbidden</D:status></D:propstat></D:response>
        <D:response><D:href>/dobry.txt</D:href>
          <D:propstat><D:prop><D:resourcetype/><D:getcontentlength>7</D:getcontentlength></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
          <D:propstat><D:prop><D:getlastmodified/></D:prop><D:status>HTTP/1.1 404 Not Found</D:status></D:propstat></D:response>
        </D:multistatus>
        """
        let e = try entries(xml)
        XCTAssertNil(e.first { $0.name == "zablokowany.txt" }?.size, "właściwości z propstat 403 nie są używane")
        XCTAssertEqual(e.first { $0.name == "dobry.txt" }?.size, 7)
    }

    func testDoctypeAndEntitiesAreRejected() {
        let xxe = """
        <?xml version="1.0"?><!DOCTYPE x [<!ENTITY e SYSTEM "file:///etc/passwd">]><D:multistatus xmlns:D="DAV:"><D:response><D:href>/&e;</D:href></D:response></D:multistatus>
        """
        XCTAssertThrowsError(try DAVMultiStatusParser.parse(Data(xxe.utf8)))
        let laughs = "<?xml version=\"1.0\"?><!DOCTYPE l [<!ENTITY a \"aaaa\"><!ENTITY b \"&a;&a;&a;&a;\">]><x>&b;</x>"
        XCTAssertThrowsError(try DAVMultiStatusParser.parse(Data(laughs.utf8)))
    }

    func testMalformedAndOversizedXMLAreErrorsNotCrashes() {
        XCTAssertThrowsError(try DAVMultiStatusParser.parse(Data("<D:multistatus".utf8)))
        XCTAssertThrowsError(try DAVMultiStatusParser.parse(Data(count: DAVMultiStatusParser.maxBytes + 1)))
    }

    func testStatusLineAndDateParsing() {
        XCTAssertEqual(DAVMultiStatusParser.parseStatusLine("HTTP/1.1 207 Multi-Status"), 207)
        XCTAssertNil(DAVMultiStatusParser.parseStatusLine("śmieci"))
        XCTAssertNotNil(DAVMultiStatusParser.parseDate("Tue, 14 Oct 2025 10:00:00 GMT"))
        XCTAssertNotNil(DAVMultiStatusParser.parseDate("2025-10-14T10:00:00Z"))
        XCTAssertNil(DAVMultiStatusParser.parseDate("wczoraj"))
    }

    // MARK: Przekierowania (polityka)

    func testRedirectPolicyBlocksDowngradeAndForeignHosts() throws {
        let c = DAVHTTPClient(baseURL: URL(string: "https://dav.example.test/")!, username: "u", password: "p", timeout: 5)
        defer { c.invalidate() }
        let from = URL(string: "https://dav.example.test/a")!
        XCTAssertNoThrow(try c.validateRedirect(from: from, to: URL(string: "https://dav.example.test/b/")!))
        XCTAssertThrowsError(try c.validateRedirect(from: from, to: URL(string: "http://dav.example.test/b")!)) { XCTAssertTrue(($0 as? NetworkError).map { if case .insecureConnectionRefused = $0 { return true } else { return false } } ?? false) }
        XCTAssertThrowsError(try c.validateRedirect(from: from, to: URL(string: "https://evil.example.test/b")!))
        XCTAssertThrowsError(try c.validateRedirect(from: from, to: URL(string: "https://dav.example.test:8443/b")!))
        XCTAssertThrowsError(try c.validateRedirect(from: from, to: URL(string: "ftp://dav.example.test/b")!))
    }

    func testPlainHTTPRequiresExplicitConsent() throws {
        let p = ConnectionProfile(name: "x", proto: .webdav, username: "u", baseURL: "http://dav.example.test/", allowInsecure: false)
        XCTAssertNotNil(p.validationError())
        let ctx = ProviderContext(credentials: ConnectionCredentials(password: "p"), hostKeyVerifier: HostKeyVerifier(store: TrustedHostsStore(url: URL(fileURLWithPath: "/dev/null"))) { _ in false })
        XCTAssertThrowsError(try WebDAVProvider(profile: p, context: ctx))
    }

    func testRequestURLsEncodeSpecialCharactersAndKeepBasePrefix() throws {
        let p = ConnectionProfile(name: "x", proto: .webdav, username: "u", baseURL: "https://dav.example.test/remote.php/dav/files/ola/")
        let ctx = ProviderContext(credentials: ConnectionCredentials(password: "p"), hostKeyVerifier: HostKeyVerifier(store: TrustedHostsStore(url: URL(fileURLWithPath: "/dev/null"))) { _ in false })
        let prov = try WebDAVProvider(profile: p, context: ctx)
        let u = try prov.url(for: RemotePath(parsing: "/Moje dokumenty/raport #1 (100%) ?&.txt"))
        XCTAssertEqual(u.absoluteString, "https://dav.example.test/remote.php/dav/files/ola/Moje%20dokumenty/raport%20%231%20%28100%25%29%20%3F%26.txt")
        let dirURL = try prov.url(for: RemotePath(parsing: "/a"), directory: true)
        let rootURL = try prov.url(for: .root, directory: true)
        XCTAssertTrue(dirURL.absoluteString.hasSuffix("/a/"))
        XCTAssertEqual(rootURL.absoluteString, "https://dav.example.test/remote.php/dav/files/ola/")
    }

    // MARK: Zabezpieczenie przed DTD obejmuje cały dokument

    func testDoctypeAfterLongCommentIsRejected() {
        let padding = String(repeating: "x", count: 100_000)
        let xml = "<?xml version=\"1.0\"?><!-- \(padding) --><!DOCTYPE foo [<!ENTITY e \"a\">]><d:multistatus xmlns:d=\"DAV:\"/>"
        XCTAssertThrowsError(try DAVMultiStatusParser.parse(Data(xml.utf8)))
    }

    func testUTF16DocumentIsRejected() {
        let xml = "<?xml version=\"1.0\" encoding=\"UTF-16\"?><!DOCTYPE foo [<!ENTITY e \"a\">]><d:multistatus xmlns:d=\"DAV:\"/>"
        let data = xml.data(using: .utf16)!
        XCTAssertThrowsError(try DAVMultiStatusParser.parse(data))
    }

    func testPlainMultiStatusStillParses() throws {
        let xml = "<?xml version=\"1.0\"?><d:multistatus xmlns:d=\"DAV:\"><d:response><d:href>/a.txt</d:href></d:response></d:multistatus>"
        XCTAssertEqual(try DAVMultiStatusParser.parse(Data(xml.utf8)).count, 1)
    }
}
