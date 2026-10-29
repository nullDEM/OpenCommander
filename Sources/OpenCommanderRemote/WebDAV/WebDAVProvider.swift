import Foundation
import OpenCommanderCore

/// Klient WebDAV (RFC 4918) na `URLSession`: PROPFIND (głębokość 0/1), GET, PUT, MKCOL, MOVE, DELETE.
/// HTTPS z standardową weryfikacją certyfikatu; HTTP tylko po jawnej zgodzie w profilu (walidacja jest w `ConnectionProfile`).
///
/// Ograniczenia: brak wznawiania i blokad (LOCK), brak PROPPATCH; serwery bez obsługi MOVE zwrócą `unsupported`.
/// Katalog bazowy (prefiks ścieżki z adresu) jest korzeniem widoku — zdalne ścieżki są względem niego.
public final class WebDAVProvider: FileProvider, @unchecked Sendable {
    private let profile: ConnectionProfile
    private let context: ProviderContext
    private let base: URL
    private let resolver: DAVHrefResolver
    private let lock = NSLock()
    private var client: DAVHTTPClient?

    public var capabilities: ProviderCapabilities {
        var c = ProviderCapabilities()
        c.reliableMetadata = true
        return c
    }

    public init(profile: ConnectionProfile, context: ProviderContext) throws {
        guard let u = profile.webDAVURL, let r = DAVHrefResolver(baseURL: u) else { throw NetworkError.invalidProfile("nieprawidłowy adres WebDAV.") }
        let scheme = u.scheme?.lowercased()
        if scheme != "https" && !(scheme == "http" && profile.allowInsecure) {
            throw NetworkError.insecureConnectionRefused("WebDAV przez HTTP wymaga jawnej zgody w profilu.")
        }
        self.profile = profile; self.context = context; self.base = u; self.resolver = r
    }

    private var secrets: [String] { context.credentials.allSecrets }

    // MARK: Adresy

    /// Adres zasobu: schemat + host + oryginalny (zakodowany) prefiks bazowy + zakodowane składowe ścieżki.
    func url(for path: RemotePath, directory: Bool = false) throws -> URL {
        var c = URLComponents()
        c.scheme = resolver.scheme
        c.host = resolver.host
        if let p = base.port { c.port = p }
        let basePath = (URLComponents(url: base, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? "")
            .split(separator: "/", omittingEmptySubsequences: true).joined(separator: "/")
        var parts: [String] = []
        if !basePath.isEmpty { parts.append(basePath) }
        parts += path.components.map(RemoteLocation.encode(component:))
        var s = "/" + parts.joined(separator: "/")
        if directory && !s.hasSuffix("/") { s += "/" }
        c.percentEncodedPath = s
        guard let url = c.url else { throw NetworkError.invalidProfile("nieprawidłowy adres WebDAV.") }
        return url
    }

    // MARK: Połączenie

    public func connect() async throws {
        let creds = profile.auth == .anonymous ? (nil as String?, nil as String?) : (profile.username.isEmpty ? nil : profile.username, context.credentials.password)
        let c = DAVHTTPClient(baseURL: base, username: creds.0, password: creds.1, timeout: TimeInterval(profile.connectTimeoutSeconds))
        do {
            let r = try await c.send("PROPFIND", url(for: .root, directory: true), headers: Self.propfindHeaders(depth: 0), body: .init(data: Self.propfindBody))
            try check(r, path: "/", ok: [207, 200])
            lock.withLock { self.client = c }
        } catch {
            c.invalidate()
            throw mapped(error, path: "/")
        }
    }

    public func disconnect() async {
        lock.withLock { let c = client; client = nil; return c }?.invalidate()
    }

    public func initialPath() async throws -> RemotePath { .root }

    private func http() throws -> DAVHTTPClient {
        guard let c = lock.withLock({ client }) else { throw NetworkError.connectionLost }
        return c
    }

    // MARK: Listowanie

    public func list(_ path: RemotePath) async throws -> [RemoteEntry] {
        do {
            let r = try await http().send("PROPFIND", url(for: path, directory: true), headers: Self.propfindHeaders(depth: 1), body: .init(data: Self.propfindBody))
            try check(r, path: path.string, ok: [207])
            return DAVListing.entries(from: try DAVMultiStatusParser.parse(r.body), directory: path, resolver: resolver).entries
        } catch { throw mapped(error, path: path.string) }
    }

    public func stat(_ path: RemotePath) async throws -> RemoteEntry? {
        do {
            let r = try await http().send("PROPFIND", url(for: path), headers: Self.propfindHeaders(depth: 0), body: .init(data: Self.propfindBody))
            if r.status == 404 || r.status == 410 { return nil }
            try check(r, path: path.string, ok: [207])
            let items = try DAVMultiStatusParser.parse(r.body)
            // Odpowiedź dotyczy dokładnie jednego zasobu; szukamy wpisu o tej ścieżce (serwer mógł dodać inne).
            guard let item = items.first(where: { $0.href.flatMap(resolver.path(forHref:)) == path }) ?? items.first,
                  let href = item.href else { return nil }
            if let s = item.status, s == 404 { return nil }
            return DAVListing.entry(name: path.lastComponent ?? "", href: href, item: item)
        } catch { throw mapped(error, path: path.string) }
    }

    // MARK: Transfery

    public func download(_ path: RemotePath, to localFile: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        guard FileManager.default.createFile(atPath: localFile.path, contents: nil) else { throw NetworkError.permissionDenied(localFile.lastPathComponent) }
        let handle = try FileHandle(forWritingTo: localFile)
        defer { try? handle.close() }
        do {
            // Bez transparentnej kompresji: rozmiar zapisanych bajtów ma się zgadzać z `Content-Length`.
            let r = try await http().send("GET", url(for: path), headers: ["Accept-Encoding": "identity"], sink: { try handle.write(contentsOf: $0) }, onReceived: progress)
            try check(r, path: path.string, ok: [200])
            if let len = r.headers["content-length"].flatMap(Int64.init) {
                let written = (try? handle.offset()).map(Int64.init) ?? -1
                if written != len { throw NetworkError.connectionLost }   // niekompletne pobranie nie może wyglądać na udane
            }
        } catch { throw mapped(error, path: path.string) }
    }

    public func upload(from localFile: URL, to path: RemotePath, overwrite: Bool, progress: @escaping @Sendable (Int64) -> Void) async throws {
        var headers: [String: String] = ["Content-Type": "application/octet-stream"]
        if !overwrite { headers["If-None-Match"] = "*" }   // serwer odrzuci (412), jeśli zasób już istnieje
        do {
            let r = try await http().send("PUT", url(for: path), headers: headers, body: .init(file: localFile), onSent: progress)
            try check(r, path: path.string, ok: [200, 201, 204])
        } catch { throw mapped(error, path: path.string) }
    }

    // MARK: Zmiany

    public func makeDirectory(_ path: RemotePath) async throws {
        do {
            let r = try await http().send("MKCOL", url(for: path, directory: true))
            if r.status == 405 { throw NetworkError.conflict(path.string) }          // już istnieje
            if r.status == 409 { throw NetworkError.notFound(path.parent.string) }   // brak katalogu nadrzędnego
            try check(r, path: path.string, ok: [201, 200])
        } catch { throw mapped(error, path: path.string) }
    }

    public func rename(_ from: RemotePath, to: RemotePath) async throws {
        let isDir = (try? await stat(from))?.isDirectory ?? false
        let headers = ["Destination": try url(for: to, directory: isDir).absoluteString, "Overwrite": "F"]
        do {
            let r = try await http().send("MOVE", url(for: from, directory: isDir), headers: headers)
            if r.status == 412 { throw NetworkError.conflict(to.string) }
            try check(r, path: from.string, ok: [201, 204, 200])
        } catch { throw mapped(error, path: from.string) }
    }

    /// Usuwa plik albo PUSTY katalog (DELETE na kolekcji kasuje rekurencyjnie, więc najpierw sprawdzamy, czy jest pusta).
    public func delete(_ path: RemotePath, isDirectory: Bool) async throws {
        if isDirectory, !(try await list(path)).isEmpty { throw NetworkError.conflict("katalog „\(path.string)” nie jest pusty") }
        if !isDirectory, let existing = try await stat(path), existing.isDirectory {
            // DELETE na kolekcji kasuje ją razem z zawartością — wołający liczył na plik, więc odmawiamy (FTP i SFTP też by odmówiły).
            throw NetworkError.conflict("„\(path.string)” jest folderem, a nie plikiem")
        }
        do {
            let r = try await http().send("DELETE", url(for: path, directory: isDirectory))
            // 207 oznacza błędy per zasób — nie udajemy sukcesu.
            try check(r, path: path.string, ok: [200, 202, 204])
        } catch { throw mapped(error, path: path.string) }
    }

    // MARK: Wspólne

    static let propfindBody = Data("""
    <?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/><d:getlastmodified/></d:prop></d:propfind>
    """.utf8)

    static func propfindHeaders(depth: Int) -> [String: String] {
        ["Depth": String(depth), "Content-Type": "application/xml; charset=utf-8"]
    }

    /// Mapuje kod HTTP na błąd domenowy (treść odpowiedzi nie trafia do komunikatu).
    private func check(_ r: DAVHTTPResult, path: String, ok: Set<Int>) throws {
        if ok.contains(r.status) { return }
        switch r.status {
        case 401: throw NetworkError.authenticationFailed
        case 403: throw NetworkError.permissionDenied(path)
        case 404, 410: throw NetworkError.notFound(path)
        case 405, 501: throw NetworkError.unsupported("metoda niedozwolona lub nieobsługiwana przez serwer (HTTP \(r.status))")
        case 409, 412: throw NetworkError.conflict(path)
        case 423: throw NetworkError.permissionDenied("\(path) (zasób zablokowany)")
        case 413, 507: throw NetworkError.noSpace
        case 300...399: throw NetworkError.invalidResponse("nieoczekiwane przekierowanie (HTTP \(r.status))")
        case 500...599: throw NetworkError.connectionFailed("serwer zgłosił błąd (HTTP \(r.status))")
        default: throw NetworkError.invalidResponse("nieoczekiwany kod odpowiedzi HTTP \(r.status)")
        }
    }

    private func mapped(_ error: Error, path: String) -> NetworkError {
        ConnectionManager.networkError(DAVHTTPClient.map(error), secrets: secrets)
    }
}
