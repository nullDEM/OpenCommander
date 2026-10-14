import Foundation

/// Zaufane klucze hostów SSH (własny, prosty format JSON — NIE jest to systemowy `known_hosts`
/// i nie obsługuje jego wariantów: zahaszowanych nazw hostów, certyfikatów, wzorców, @revoked).
/// Klucz wpisu: „host:port”. Zaufanie jest zapisywane dopiero po jawnej akceptacji użytkownika.
public struct TrustedHosts: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable, Identifiable {
        public var id: String { "\(host):\(port)" }
        public let host: String
        public let port: Int
        public let keyType: String
        public let fingerprint: String
        public let trustedAt: Date
    }

    public private(set) var entries: [Entry] = []
    public init() {}

    public enum Verdict: Equatable, Sendable {
        case trusted
        case unknown
        case changed(expected: String)
    }

    static func key(_ host: String, _ port: Int) -> String { "\(host.lowercased()):\(port)" }

    public func verdict(for info: HostKeyInfo) -> Verdict {
        let k = Self.key(info.host, info.port)
        guard let known = entries.first(where: { Self.key($0.host, $0.port) == k && $0.keyType == info.keyType }) else {
            // Znany host z kluczem INNEGO typu to też zmiana — serwer, który wcześniej pokazał inny klucz, nie może go podmienić po cichu.
            if let other = entries.first(where: { Self.key($0.host, $0.port) == k }) { return .changed(expected: other.fingerprint) }
            return .unknown
        }
        return known.fingerprint == info.fingerprint ? .trusted : .changed(expected: known.fingerprint)
    }

    /// Zapisuje zaufanie. Wywołuj wyłącznie po jawnej akceptacji użytkownika. Nie zastępuje istniejącego,
    /// innego klucza tego hosta — najpierw trzeba go świadomie usunąć (`remove`).
    @discardableResult
    public mutating func trust(_ info: HostKeyInfo, now: Date = Date()) -> Bool {
        guard verdict(for: info) == .unknown else { return verdict(for: info) == .trusted }
        entries.append(Entry(host: info.host, port: info.port, keyType: info.keyType, fingerprint: info.fingerprint, trustedAt: now))
        return true
    }

    public mutating func remove(id: String) { entries.removeAll { $0.id == id } }
    public mutating func removeAll(host: String, port: Int) { entries.removeAll { Self.key($0.host, $0.port) == Self.key(host, port) } }
}

public struct TrustedHostsStore: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()

    public init(url: URL) { self.url = url }

    public static func defaultURL(bundleID: String = Bundle.main.bundleIdentifier ?? "org.opencommander.OpenCommander") -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(bundleID, isDirectory: true).appendingPathComponent("trusted_hosts.json")
    }

    public func load() -> TrustedHosts {
        lock.withLock {
            guard let data = try? Data(contentsOf: url), let t = try? JSONDecoder.iso.decode(TrustedHosts.self, from: data) else { return TrustedHosts() }
            return t
        }
    }

    public func save(_ hosts: TrustedHosts) throws {
        try lock.withLock {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder.iso.encode(hosts).write(to: url, options: .atomic)
        }
    }
}

extension JSONEncoder {
    static var iso: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e }
}
extension JSONDecoder {
    static var iso: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}
