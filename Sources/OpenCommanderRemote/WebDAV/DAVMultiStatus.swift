import Foundation
import OpenCommanderCore

/// Odpowiedź `207 Multi-Status` (RFC 4918) sprowadzona do prostych struktur. Parser jest bezpieczny: nie rozwiązuje
/// encji zewnętrznych, odrzuca dokumenty z DOCTYPE/ENTITY (WebDAV ich nie potrzebuje) i ogranicza rozmiar wejścia.
struct DAVResponseItem: Equatable {
    struct PropStat: Equatable {
        var status: Int?
        var isCollection: Bool?
        var size: Int64?
        var modified: Date?
    }
    var hrefs: [String] = []
    var status: Int?              // status całego zasobu (gdy brak propstat)
    var propstats: [PropStat] = []
    var href: String? { hrefs.first }

    /// Właściwości z pierwszego propstat ze statusem 2xx (brak statusu = 200 wg RFC).
    var okProps: PropStat? { propstats.first { ($0.status ?? 200) / 100 == 2 } }
}

enum DAVMultiStatusParser {
    static let maxBytes = 16 * 1024 * 1024

    static func parse(_ data: Data) throws -> [DAVResponseItem] {
        guard data.count <= maxBytes else { throw NetworkError.invalidResponse("odpowiedź serwera jest zbyt duża") }
        // Nie dopuszczamy definicji typu dokumentu ani encji (ochrona przed XXE / „billion laughs”).
        // DOCTYPE może wystąpić wyłącznie przed elementem głównym, więc wystarczy początek dokumentu.
        let head = String(decoding: data.prefix(65_536), as: UTF8.self).lowercased()
        if head.contains("<!doctype") || head.contains("<!entity") {
            throw NetworkError.invalidResponse("odpowiedź zawiera niedozwoloną definicję typu dokumentu")
        }
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.shouldReportNamespacePrefixes = false
        parser.delegate = delegate
        guard parser.parse(), delegate.error == nil else {
            throw NetworkError.invalidResponse("nieprawidłowy XML Multi-Status")
        }
        return delegate.items
    }

    static func parseStatusLine(_ s: String) -> Int? {
        // „HTTP/1.1 200 OK”
        let parts = s.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/") else { return nil }
        return Int(parts[1])
    }

    private static let rfc1123: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"; return f
    }()
    private static let iso = ISO8601DateFormatter()

    static func parseDate(_ s: String) -> Date? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return rfc1123.date(from: t) ?? iso.date(from: t)
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        static let dav = "DAV:"
        var items: [DAVResponseItem] = []
        var error: Error?
        private var stack: [String] = []
        private var current: DAVResponseItem?
        private var ps: DAVResponseItem.PropStat?
        private var text = ""

        private func isDAV(_ ns: String?) -> Bool { ns == Self.dav }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            let local = isDAV(namespaceURI) ? name : "{other}" + name
            stack.append(local)
            text = ""
            switch local {
            case "response": current = DAVResponseItem()
            case "propstat": ps = DAVResponseItem.PropStat()
            case "collection" where stack.dropLast().last == "resourcetype":
                ps?.isCollection = true
            case "resourcetype":
                if ps?.isCollection == nil { ps?.isCollection = false }
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            defer { stack.removeLast(); text = "" }
            guard let local = stack.last else { return }
            let parent = stack.dropLast().last
            switch local {
            case "href" where parent == "response": current?.hrefs.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
            case "status":
                let code = DAVMultiStatusParser.parseStatusLine(text)
                if parent == "propstat" { ps?.status = code } else if parent == "response" { current?.status = code }
            case "getcontentlength" where parent == "prop": ps?.size = Int64(text.trimmingCharacters(in: .whitespaces))
            case "getlastmodified" where parent == "prop": ps?.modified = DAVMultiStatusParser.parseDate(text)
            case "propstat": if let p = ps { current?.propstats.append(p) }; ps = nil
            case "response": if let c = current { items.append(c) }; current = nil
            default: break
            }
        }

        func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) { error = parseError }
    }
}

/// Zamiana href z odpowiedzi serwera na ścieżkę względem adresu bazowego połączenia.
/// Href może być bezwzględnym adresem albo ścieżką, może zawierać kodowanie procentowe lub surowe znaki Unicode.
struct DAVHrefResolver {
    let scheme: String
    let host: String
    let port: Int
    /// Składowe prefiksu ścieżki z adresu bazowego (zdekodowane), np. `["remote.php","dav","files","ola"]`.
    let prefix: [String]

    init?(baseURL: URL) {
        guard let scheme = baseURL.scheme?.lowercased(), let host = baseURL.host?.lowercased() else { return nil }
        self.scheme = scheme; self.host = host
        self.port = baseURL.port ?? (scheme == "https" ? 443 : 80)
        guard let comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        var out: [String] = []
        for part in comps.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: true) {
            guard let d = String(part).removingPercentEncoding else { return nil }
            out.append(d)
        }
        self.prefix = out
    }

    /// `nil`, gdy href wskazuje poza serwer/prefiks bazowy albo zawiera niedozwoloną składową (`..`, `/` po dekodowaniu, NUL).
    func path(forHref href: String) -> RemotePath? {
        var comps = URLComponents(string: href)
        if comps == nil {
            var allowed = CharacterSet.urlPathAllowed; allowed.insert(charactersIn: "%")
            comps = href.addingPercentEncoding(withAllowedCharacters: allowed).flatMap { URLComponents(string: $0) }
        }
        guard let c = comps else { return nil }
        if let h = c.host {
            guard h.lowercased() == host else { return nil }
            if let s = c.scheme?.lowercased(), s != scheme { return nil }
            if (c.port ?? port) != port { return nil }
        } else if c.scheme != nil { return nil }
        var decoded: [String] = []
        for part in c.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: true) {
            guard let d = String(part).removingPercentEncoding, RemotePath.isValidName(d) else { return nil }
            decoded.append(d)
        }
        guard decoded.count >= prefix.count, Array(decoded.prefix(prefix.count)) == prefix else { return nil }
        return RemotePath(parsing: decoded.dropFirst(prefix.count).joined(separator: "/"))
    }
}

/// Zamiana odpowiedzi Multi-Status na wpisy katalogu `directory`.
enum DAVListing {
    struct Result { var entries: [RemoteEntry]; var skipped: Int }

    static func entries(from items: [DAVResponseItem], directory: RemotePath, resolver: DAVHrefResolver) -> Result {
        var out: [RemoteEntry] = []
        var skipped = 0
        var seen = Set<String>()
        for item in items {
            guard let href = item.href, let p = resolver.path(forHref: href) else { skipped += 1; continue }
            if p == directory { continue }                 // sam katalog nie jest swoim wpisem
            guard p.parent == directory, let name = p.lastComponent else { skipped += 1; continue }   // tylko bezpośrednie dzieci
            guard seen.insert(name).inserted else { continue }
            out.append(entry(name: name, href: href, item: item))
        }
        return Result(entries: out, skipped: skipped)
    }

    /// Wpis dla jednego zasobu. Brak właściwości (błąd per zasób lub pominięte pole) nie przerywa listowania:
    /// rodzaj bywa wtedy odgadywany po ukośniku na końcu href (kolekcje go zwykle mają), rozmiar zostaje nieznany.
    static func entry(name: String, href: String, item: DAVResponseItem) -> RemoteEntry {
        let props = item.okProps
        let isDir = props?.isCollection ?? href.hasSuffix("/")
        return RemoteEntry(name: name, kind: isDir ? .directory : .file, size: isDir ? nil : props?.size, modified: props?.modified)
    }
}
