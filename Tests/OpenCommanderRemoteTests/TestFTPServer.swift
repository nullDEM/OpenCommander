import Foundation
import Network
import OpenCommanderCore

/// Minimalny serwer FTP w procesie testowym (127.0.0.1, katalog tymczasowy): tryb pasywny, MLSD/LIST, RETR, STOR, DELE, MKD, RMD,
/// RNFR/RNTO, SIZE, PWD/CWD, opcjonalnie TLS niejawny (FTPS). Tylko do testów — nie jest pełną implementacją RFC 959.
final class TestFTPServer: @unchecked Sendable {
    let root: URL
    let username = "ola", password = "tajne-haslo-ftp-123"
    var supportsMLSD = true
    var supportsAuthTLS = false          // gdy false: AUTH TLS → 502 (test „bez cichego obniżania”)
    var homeDir = "/"                     // wirtualny katalog domowy zwracany przez PWD
    var dropStorAfterBytes: Int?          // zrywa połączenia po tylu bajtach danych STOR
    var truncateRetr = false              // RETR: wysyła połowę danych i zrywa połączenie
    var brokenPassiveIP = false           // PASV zwraca obcy adres (powinien zostać zignorowany przez klienta)
    private let lock = NSLock()
    private var _commands: [String] = []
    private let listener: NWListener
    private let dataParams: NWParameters
    private let queue = DispatchQueue(label: "oc.test.ftp")
    private(set) var port = 0
    private var sessions: [Session] = []

    /// Komendy odebrane od klienta BEZ argumentów PASS (do asercji; hasło nigdy nie jest zapisywane).
    var commands: [String] { lock.withLock { _commands } }

    static func start(root: URL, tls: NWParameters? = nil) async throws -> TestFTPServer {
        let s = try TestFTPServer(root: root, tls: tls)
        try await s.run()
        return s
    }

    private init(root: URL, tls: NWParameters?) throws {
        self.root = root
        listener = try NWListener(using: tls ?? .tcp, on: .any)
        dataParams = tls ?? .tcp
    }

    private final class StartBox: @unchecked Sendable { var done = false }

    private func run() async throws {
        listener.newConnectionHandler = { [weak self] c in self?.accept(c) }
        let box = StartBox()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { st in
                guard !box.done else { return }
                switch st {
                case .ready: box.done = true; cont.resume()
                case .failed(let e): box.done = true; cont.resume(throwing: e)
                default: break
                }
            }
            listener.start(queue: queue)
        }
        port = Int(listener.port?.rawValue ?? 0)
    }

    func stop() { listener.cancel(); queue.async { self.sessions.forEach { $0.close() }; self.sessions.removeAll() } }
    fileprivate func record(_ s: String) { lock.withLock { _commands.append(s) } }

    private func accept(_ conn: NWConnection) {
        let s = Session(server: self, control: conn)
        sessions.append(s)
        s.start()
    }

    // MARK: Sesja

    fileprivate final class Session: @unchecked Sendable {
        unowned let server: TestFTPServer
        let control: NWConnection
        var buffer = Data()
        var loggedIn = false, userOK = false
        var cwd = "/"
        var rnfr: URL?
        var dataListener: NWListener?
        var dataConn: NWConnection?
        var pending: ((NWConnection) -> Void)?

        init(server: TestFTPServer, control: NWConnection) { self.server = server; self.control = control }

        func start() {
            control.start(queue: server.queue)
            reply("220 Test FTP")
            readLoop()
        }

        func close() { control.cancel(); dataConn?.cancel(); dataListener?.cancel() }

        func reply(_ line: String) { control.send(content: Data((line + "\r\n").utf8), completion: .contentProcessed { _ in }) }

        func readLoop() {
            control.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, done, error in
                guard let self else { return }
                if let data { self.buffer.append(data) }
                while let r = self.buffer.range(of: Data("\r\n".utf8)) {
                    let line = String(decoding: self.buffer.subdata(in: 0..<r.lowerBound), as: UTF8.self)
                    self.buffer.removeSubrange(0..<r.upperBound)
                    self.handle(line)
                }
                if done || error != nil { self.close(); return }
                self.readLoop()
            }
        }

        // MARK: Ścieżki

        func resolve(_ arg: String) -> (virtual: [String], url: URL)? {
            var comps: [String] = arg.hasPrefix("/") ? [] : cwd.split(separator: "/").map(String.init)
            for p in arg.split(separator: "/", omittingEmptySubsequences: true) {
                if p == ".." { if !comps.isEmpty { comps.removeLast() } } else if p != "." { comps.append(String(p)) }
            }
            return (comps, comps.reduce(server.root) { $0.appendingPathComponent($1) })
        }

        // MARK: Polecenia

        func handle(_ line: String) {
            let cmd = line.split(separator: " ", maxSplits: 1).first.map { String($0).uppercased() } ?? ""
            let arg = line.contains(" ") ? String(line[line.index(after: line.firstIndex(of: " ")!)...]) : ""
            server.record(cmd == "PASS" ? "PASS" : line)
            let fm = FileManager.default
            if !["USER", "PASS", "QUIT", "FEAT", "AUTH", "SYST", "OPTS", "PBSZ", "PROT"].contains(cmd), !loggedIn { reply("530 Please login with USER and PASS"); return }
            switch cmd {
            case "USER": userOK = arg == server.username; reply("331 Password required")
            case "PASS":
                if userOK && arg == server.password { loggedIn = true; cwd = server.homeDir; reply("230 Logged in") } else { reply("530 Login incorrect") }
            case "AUTH": reply(server.supportsAuthTLS ? "234 Proceed" : "502 TLS not supported")
            case "PBSZ": reply("200 PBSZ=0")
            case "PROT": reply("200 Protection set")
            case "SYST": reply("215 UNIX Type: L8")
            case "OPTS": reply("200 OK")
            case "FEAT":
                reply("211-Features:"); reply(" UTF8"); reply(" EPSV")
                if server.supportsMLSD { reply(" MLST type*;size*;modify*;"); reply(" MLSD") }
                reply("211 End")
            case "TYPE": reply("200 Type set")
            case "PWD": reply("257 \"\(cwd.replacingOccurrences(of: "\"", with: "\"\""))\" is current directory")
            case "CWD":
                guard let r = resolve(arg) else { reply("550 No such directory"); return }
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: r.url.path, isDirectory: &isDir), isDir.boolValue { cwd = "/" + r.virtual.joined(separator: "/"); reply("250 OK") }
                else { reply("550 No such directory") }
            case "CDUP": cwd = "/" + cwd.split(separator: "/").dropLast().joined(separator: "/"); reply("250 OK")
            case "EPSV": openPassive { port in self.reply("229 Entering Extended Passive Mode (|||\(port)|)") }
            case "PASV":
                openPassive { port in
                    let ip = self.server.brokenPassiveIP ? "10,255,255,1" : "127,0,0,1"
                    self.reply("227 Entering Passive Mode (\(ip),\(port / 256),\(port % 256))")
                }
            case "MLSD", "LIST", "NLST":
                if cmd == "MLSD" && !server.supportsMLSD { reply("500 Unknown command"); return }
                guard let r = resolve(arg.isEmpty ? "." : arg) else { reply("550 No such directory"); return }
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: r.url.path, isDirectory: &isDir), isDir.boolValue else { reply("550 No such directory"); return }
                let text = listing(r.url, mlsd: cmd == "MLSD")
                transfer { conn in self.sendThenClose(conn, Data(text.utf8)) }
            case "RETR":
                guard let r = resolve(arg), let data = try? Data(contentsOf: r.url) else { reply("550 No such file"); return }
                transfer { conn in
                    if self.server.truncateRetr {
                        conn.send(content: data.prefix(data.count / 2), completion: .contentProcessed { _ in self.close() })
                    } else { self.sendThenClose(conn, data) }
                }
            case "STOR":
                guard let r = resolve(arg), fm.fileExists(atPath: r.url.deletingLastPathComponent().path) else { reply("550 Cannot store"); return }
                transfer { conn in self.receive(conn, into: r.url) }
            case "DELE":
                guard let r = resolve(arg), fm.fileExists(atPath: r.url.path) else { reply("550 No such file"); return }
                do { try fm.removeItem(at: r.url); reply("250 Deleted") } catch { reply("550 Cannot delete") }
            case "MKD":
                guard let r = resolve(arg), !fm.fileExists(atPath: r.url.path) else { reply("550 Exists"); return }
                do { try fm.createDirectory(at: r.url, withIntermediateDirectories: false); reply("257 \"/\(r.virtual.joined(separator: "/"))\" created") } catch { reply("550 Cannot create") }
            case "RMD":
                guard let r = resolve(arg), fm.fileExists(atPath: r.url.path) else { reply("550 No such directory"); return }
                if ((try? fm.contentsOfDirectory(atPath: r.url.path)) ?? []).isEmpty { try? fm.removeItem(at: r.url); reply("250 Removed") } else { reply("550 Directory not empty") }
            case "RNFR":
                guard let r = resolve(arg), fm.fileExists(atPath: r.url.path) else { reply("550 No such file"); return }
                rnfr = r.url; reply("350 Ready for RNTO")
            case "RNTO":
                guard let from = rnfr, let r = resolve(arg) else { reply("503 RNFR first"); return }
                rnfr = nil
                do { try fm.moveItem(at: from, to: r.url); reply("250 Renamed") } catch { reply("550 Cannot rename") }
            case "SIZE":
                guard let r = resolve(arg), let a = try? fm.attributesOfItem(atPath: r.url.path), let n = a[.size] as? NSNumber else { reply("550 No such file"); return }
                reply("213 \(n)")
            case "QUIT": reply("221 Bye"); close()
            default: reply("502 Command not implemented")
            }
        }

        func listing(_ dir: URL, mlsd: Bool) -> String {
            let fm = FileManager.default
            let names = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
            let fmt = DateFormatter(); fmt.locale = Locale(identifier: "en_US_POSIX"); fmt.timeZone = TimeZone(identifier: "UTC")
            var out = ""
            for n in names {
                let u = dir.appendingPathComponent(n)
                let a = try? fm.attributesOfItem(atPath: u.path)
                let isDir = (a?[.type] as? FileAttributeType) == .typeDirectory
                let size = (a?[.size] as? NSNumber)?.int64Value ?? 0
                let date = (a?[.modificationDate] as? Date) ?? Date()
                if mlsd {
                    fmt.dateFormat = "yyyyMMddHHmmss"
                    out += "type=\(isDir ? "dir" : "file");size=\(size);modify=\(fmt.string(from: date)); \(n)\r\n"
                } else {
                    fmt.dateFormat = "MMM dd HH:mm"
                    out += "\(isDir ? "d" : "-")rw-r--r-- 1 ftp ftp \(size) \(fmt.string(from: date)) \(n)\r\n"
                }
            }
            return out
        }

        // MARK: Kanał danych (pasywny)

        func openPassive(_ announce: @escaping (Int) -> Void) {
            dataListener?.cancel(); dataConn?.cancel(); dataConn = nil
            guard let l = try? NWListener(using: server.dataParams, on: .any) else { reply("425 Cannot open passive"); return }
            dataListener = l
            l.newConnectionHandler = { [weak self] c in
                guard let self else { return }
                c.start(queue: self.server.queue)
                if let p = self.pending { self.pending = nil; p(c) } else { self.dataConn = c }
            }
            l.stateUpdateHandler = { st in if case .ready = st { announce(Int(l.port?.rawValue ?? 0)) } }
            l.start(queue: server.queue)
        }

        func transfer(_ body: @escaping (NWConnection) -> Void) {
            reply("150 Opening data connection")
            if let c = dataConn { dataConn = nil; body(c) } else { pending = body }
        }

        func sendThenClose(_ conn: NWConnection, _ data: Data) {
            conn.send(content: data, completion: .contentProcessed { [weak self] _ in
                conn.cancel(); self?.reply("226 Transfer complete")
            })
        }

        func receive(_ conn: NWConnection, into url: URL, _ acc: Data = Data()) {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, done, error in
                guard let self else { return }
                var buf = acc; if let data { buf.append(data) }
                if let limit = self.server.dropStorAfterBytes, buf.count >= limit { self.close(); return }
                if done || error != nil {
                    if error == nil, (try? buf.write(to: url)) != nil { self.reply("226 Transfer complete") } else { self.reply("426 Transfer aborted") }
                    conn.cancel(); return
                }
                self.receive(conn, into: url, buf)
            }
        }
    }
}
