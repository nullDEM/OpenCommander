import Foundation

/// Ścieżka POSIX na serwerze zdalnym, trzymana jako lista składowych (nie jako `file://` URL).
/// Składowe nigdy nie zawierają „/”, „.” ani „..” — dzięki temu mapowanie na ścieżkę lokalną nie może wyjść poza folder.
public struct RemotePath: Hashable, Sendable, Codable, CustomStringConvertible {
    public let components: [String]

    public static let root = RemotePath(components: [])

    private init(components: [String]) { self.components = components }

    /// Parsuje ścieżkę bezwzględną lub względną (traktowaną jak bezwzględna). „.” i puste segmenty są pomijane,
    /// „..” cofa o jeden poziom i nigdy nie wychodzi powyżej korzenia.
    public init(parsing path: String) {
        var out: [String] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": if !out.isEmpty { out.removeLast() }
            default: out.append(String(part))
            }
        }
        self.components = out
    }

    public var string: String { "/" + components.joined(separator: "/") }
    public var description: String { string }
    public var isRoot: Bool { components.isEmpty }
    public var lastComponent: String? { components.last }
    public var parent: RemotePath { isRoot ? self : RemotePath(components: Array(components.dropLast())) }

    /// Poprawna pojedyncza nazwa elementu (bez separatorów, „.”, „..”, pusta, bez NUL).
    public static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }

    public func appending(_ name: String) throws -> RemotePath {
        guard Self.isValidName(name) else { throw NetworkError.invalidPath(name) }
        return RemotePath(components: components + [name])
    }

    public func isInside(_ other: RemotePath) -> Bool {
        components.count > other.components.count && Array(components.prefix(other.components.count)) == other.components
    }
}

/// Lokalizacja zdalna: identyfikator połączenia + ścieżka. Ma własny schemat URL (`ocremote`), żeby nigdy
/// nie dało się jej pomylić z plikiem lokalnym i żeby dwa serwery z tą samą ścieżką miały różne tożsamości.
public struct RemoteLocation: Hashable, Sendable {
    public static let scheme = "ocremote"
    public let connectionID: UUID
    public let path: RemotePath

    public init(connectionID: UUID, path: RemotePath) {
        self.connectionID = connectionID
        self.path = path
    }

    /// Znaki niezakodowane: wyłącznie niezarezerwowane z RFC 3986. Wszystko inne (spacja, #, %, ?, &, Unicode…)
    /// jest kodowane per składowa, więc separatory „/” zostają nietknięte.
    static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    public static func encode(component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: unreserved) ?? component
    }

    public var url: URL {
        var c = URLComponents()
        c.scheme = Self.scheme
        c.host = connectionID.uuidString.lowercased()
        c.percentEncodedPath = "/" + path.components.map(Self.encode(component:)).joined(separator: "/")
        return c.url ?? URL(string: "\(Self.scheme)://\(connectionID.uuidString.lowercased())/")!
    }

    public init?(url: URL) {
        guard url.scheme == Self.scheme, let host = url.host, let id = UUID(uuidString: host),
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let raw = comps.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: true)
        var decoded: [String] = []
        for r in raw {
            guard let d = String(r).removingPercentEncoding, RemotePath.isValidName(d) else { return nil }
            decoded.append(d)
        }
        self.connectionID = id
        self.path = RemotePath(parsing: decoded.joined(separator: "/"))
    }

    public func appending(_ name: String) throws -> RemoteLocation {
        RemoteLocation(connectionID: connectionID, path: try path.appending(name))
    }
    public var parent: RemoteLocation { RemoteLocation(connectionID: connectionID, path: path.parent) }
}

public extension URL {
    var isRemoteLocation: Bool { scheme == RemoteLocation.scheme }
    var remoteLocation: RemoteLocation? { RemoteLocation(url: self) }
}

/// Mapowanie nazw ze zdalnego listowania na ścieżki lokalne w wybranym katalogu pobierania.
public enum LocalMapping {
    /// Zwraca adres lokalny `root/…/name` albo `nil`, gdy nazwa mogłaby wyjść poza `root` (path traversal)
    /// lub jest niedozwolona. Nazwy pochodzące z serwera są niezaufane.
    public static func url(for name: String, in root: URL) -> URL? {
        guard RemotePath.isValidName(name) else { return nil }
        let candidate = root.appendingPathComponent(name)
        let rootPath = root.standardizedFileURL.path
        let candPath = candidate.standardizedFileURL.path
        guard candPath.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/") else { return nil }
        return candidate
    }
}
