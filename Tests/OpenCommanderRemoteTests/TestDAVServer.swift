import Foundation
import Network
import OpenCommanderCore

/// Minimalny serwer WebDAV w procesie testowym (127.0.0.1, katalog tymczasowy): PROPFIND, GET, PUT, MKCOL, MOVE, DELETE,
/// Basic auth, prefiks ścieżki, przekierowania i wstrzykiwanie odpowiedzi. Jedno żądanie na połączenie. Tylko do testów.
final class TestDAVServer: @unchecked Sendable {
    struct Recorded { var method: String; var path: String; var headers: [String: String]; var bodySize: Int }
    struct Canned { var status: Int; var headers: [String: String] = [:]; var body: String = "" }

    let root: URL
    let prefix: String                 // np. "" albo "/remote.php/dav/files/ola"
    let username = "ola", password = "tajne-haslo-dav-123"
    var requireAuth = true
    /// Klucz „METHOD /surowa/ścieżka” → gotowa odpowiedź (zamiast obsługi z systemu plików).
    var canned: [String: Canned] = [:]
    /// Zamyka połączenie po tylu bajtach treści PUT (symulacja zerwania w trakcie uploadu).
    var dropPutAfterBytes: Int?
    /// GET: zadeklaruj pełny Content-Length, ale wyślij tylko połowę i zamknij połączenie.
    var truncateGet = false

    private let lock = NSLock()
    private var _requests: [Recorded] = []
    private let listener: NWListener
    private let queue = DispatchQueue(label: "oc.test.dav")
    private(set) var port = 0

    var requests: [Recorded] { lock.withLock { _requests } }
    var baseURL: String { "http://127.0.0.1:\(port)\(prefix)/" }

    static func start(root: URL, prefix: String = "", tls: NWParameters? = nil) async throws -> TestDAVServer {
        let s = try TestDAVServer(root: root, prefix: prefix, tls: tls)
        try await s.run()
        return s
    }

    private init(root: URL, prefix: String, tls: NWParameters?) throws {
        self.root = root; self.prefix = prefix
        listener = try NWListener(using: tls ?? .tcp, on: .any)
    }

    private func run() async throws {
        listener.newConnectionHandler = { [weak self] c in self?.handle(c) }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = NSLock(); var done = false
            listener.stateUpdateHandler = { st in
                once.lock(); defer { once.unlock() }
                guard !done else { return }
                switch st {
                case .ready: done = true; cont.resume()
                case .failed(let e): done = true; cont.resume(throwing: e)
                default: break
                }
            }
            listener.start(queue: queue)
        }
        port = Int(listener.port?.rawValue ?? 0)
    }

    func stop() { listener.cancel() }

    // MARK: Obsługa połączenia

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, Data())
    }

    private func receive(_ conn: NWConnection, _ acc: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, done, error in
            guard let self else { return }
            var buf = acc; if let data { buf.append(data) }
            if let (req, bodyStart, length) = self.parseHead(buf) {
                // Zerwanie w trakcie PUT: po przekroczeniu progu zamykamy bez odpowiedzi.
                if req.method == "PUT", let limit = self.dropPutAfterBytes, buf.count - bodyStart >= limit { conn.cancel(); return }
                if buf.count - bodyStart >= length {
                    let body = buf.subdata(in: bodyStart..<(bodyStart + length))
                    self.respond(conn, req, body)
                    return
                }
            }
            if done || error != nil { conn.cancel(); return }
            self.receive(conn, buf)
        }
    }

    private struct Head { var method: String; var path: String; var headers: [String: String] }

    private func parseHead(_ buf: Data) -> (Head, Int, Int)? {
        guard let r = buf.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let text = String(decoding: buf.subdata(in: 0..<r.lowerBound), as: UTF8.self)
        let lines = text.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for l in lines.dropFirst() { if let i = l.firstIndex(of: ":") { headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces) } }
        return (Head(method: String(first[0]), path: String(first[1]), headers: headers), r.upperBound, Int(headers["content-length"] ?? "0") ?? 0)
    }

    private func send(_ conn: NWConnection, status: Int, headers: [String: String] = [:], body: Data = Data(), declaredLength: Int? = nil, closeEarly: Bool = false) {
        let reason = HTTPURLResponse.localizedString(forStatusCode: status)
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: \(declaredLength ?? body.count)\r\nConnection: close\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func respond(_ conn: NWConnection, _ req: Head, _ body: Data) {
        lock.withLock { _requests.append(Recorded(method: req.method, path: req.path, headers: req.headers, bodySize: body.count)) }
        let key = "\(req.method) \(req.path)"
        if let c = canned[key] { send(conn, status: c.status, headers: c.headers, body: Data(c.body.utf8)); return }
        if requireAuth {
            let expected = "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
            if req.headers["authorization"] != expected {
                send(conn, status: 401, headers: ["WWW-Authenticate": "Basic realm=\"test\""]); return
            }
        }
        guard let rel = relativePath(req.path), let fs = fileURL(rel) else { send(conn, status: 404); return }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: fs.path, isDirectory: &isDir)
        switch req.method {
        case "PROPFIND":
            guard exists else { send(conn, status: 404); return }
            let depth = req.headers["depth"] ?? "1"
            var items = [(rel, fs)]
            if depth != "0", isDir.boolValue, let kids = try? fm.contentsOfDirectory(atPath: fs.path).sorted() {
                for k in kids { items.append((rel + [k], fs.appendingPathComponent(k))) }
            }
            let xml = multistatus(items)
            send(conn, status: 207, headers: ["Content-Type": "application/xml; charset=utf-8"], body: Data(xml.utf8))
        case "GET":
            guard exists, !isDir.boolValue, let data = try? Data(contentsOf: fs) else { send(conn, status: 404); return }
            if truncateGet { send(conn, status: 200, body: data.prefix(data.count / 2), declaredLength: data.count) }
            else { send(conn, status: 200, body: data) }
        case "PUT":
            if exists && isDir.boolValue { send(conn, status: 405); return }
            if req.headers["if-none-match"] == "*" && exists { send(conn, status: 412); return }
            guard fm.fileExists(atPath: fs.deletingLastPathComponent().path) else { send(conn, status: 409); return }
            do { try body.write(to: fs); send(conn, status: exists ? 204 : 201) } catch { send(conn, status: 500) }
        case "MKCOL":
            if exists { send(conn, status: 405); return }
            guard fm.fileExists(atPath: fs.deletingLastPathComponent().path) else { send(conn, status: 409); return }
            do { try fm.createDirectory(at: fs, withIntermediateDirectories: false); send(conn, status: 201) } catch { send(conn, status: 500) }
        case "DELETE":
            guard exists else { send(conn, status: 404); return }
            do { try fm.removeItem(at: fs); send(conn, status: 204) } catch { send(conn, status: 500) }
        case "MOVE":
            guard exists, let dest = req.headers["destination"], let u = URL(string: dest),
                  let drel = relativePath(u.path), let dfs = fileURL(drel) else { send(conn, status: 400); return }
            if fm.fileExists(atPath: dfs.path) { send(conn, status: req.headers["overwrite"] == "F" ? 412 : 204); return }
            do { try fm.moveItem(at: fs, to: dfs); send(conn, status: 201) } catch { send(conn, status: 409) }
        default:
            send(conn, status: 405)
        }
    }

    // MARK: Ścieżki i XML

    private func relativePath(_ rawPath: String) -> [String]? {
        let pathOnly = rawPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rawPath
        let comps = pathOnly.split(separator: "/", omittingEmptySubsequences: true).compactMap { String($0).removingPercentEncoding }
        let pre = prefix.split(separator: "/").map(String.init)
        guard comps.count >= pre.count, Array(comps.prefix(pre.count)) == pre else { return nil }
        let rel = Array(comps.dropFirst(pre.count))
        return rel.allSatisfy(RemotePath.isValidName) ? rel : nil
    }

    private func fileURL(_ rel: [String]) -> URL? { rel.reduce(root) { $0.appendingPathComponent($1) } }

    private func href(_ rel: [String], dir: Bool) -> String {
        let pre = prefix.split(separator: "/").map(String.init)
        let parts = (pre + rel).map(RemoteLocation.encode(component:))
        var s = "/" + parts.joined(separator: "/")
        if dir && !s.hasSuffix("/") { s += "/" }
        return s
    }

    private func multistatus(_ items: [([String], URL)]) -> String {
        var out = "<?xml version=\"1.0\" encoding=\"utf-8\"?><D:multistatus xmlns:D=\"DAV:\">"
        let fmt = DateFormatter(); fmt.locale = Locale(identifier: "en_US_POSIX"); fmt.timeZone = TimeZone(identifier: "GMT")
        fmt.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        for (rel, fs) in items {
            let attrs = try? FileManager.default.attributesOfItem(atPath: fs.path)
            let dir = (attrs?[.type] as? FileAttributeType) == .typeDirectory
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            let mod = (attrs?[.modificationDate] as? Date).map(fmt.string(from:)) ?? ""
            out += "<D:response><D:href>\(href(rel, dir: dir))</D:href><D:propstat><D:prop>"
            out += dir ? "<D:resourcetype><D:collection/></D:resourcetype>" : "<D:resourcetype/><D:getcontentlength>\(size)</D:getcontentlength>"
            out += "<D:getlastmodified>\(mod)</D:getlastmodified></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>"
        }
        return out + "</D:multistatus>"
    }
}
