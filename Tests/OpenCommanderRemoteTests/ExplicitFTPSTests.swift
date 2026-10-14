import XCTest
@testable import OpenCommanderRemote
@testable import OpenCommanderCore

/// FTPS jawny (AUTH TLS na porcie sterującym) — serwer testowy w Pythonie (`ssl` z biblioteki standardowej), bo Network.framework
/// nie potrafi podnieść już otwartego połączenia do TLS. Pomijany, gdy brak python3/openssl.
final class ExplicitFTPSTests: XCTestCase {
    var dir: URL!, root: URL!
    var proc: Process?

    override func setUp() async throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().appendingPathComponent("oc-xftps-\(UUID().uuidString)")
        root = dir.appendingPathComponent("srv")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() async throws {
        proc?.terminate(); proc?.waitUntilExit()
        try? FileManager.default.removeItem(at: dir)
    }

    static let script = #"""
    import socket, ssl, sys, os, threading, time
    root, certfile, keyfile, logfile = sys.argv[1:5]
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(certfile, keyfile)
    srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); srv.bind(("127.0.0.1", 0)); srv.listen(5)
    print(srv.getsockname()[1], flush=True)
    log = open(logfile, "a", buffering=1)
    def real(cwd, arg):
        parts = [] if arg.startswith("/") else [p for p in cwd.split("/") if p]
        for p in arg.split("/"):
            if p in ("", "."): continue
            if p == "..":
                if parts: parts.pop()
            else: parts.append(p)
        return parts, os.path.join(root, *parts)
    def session(c):
        f = c
        def send(s): f.sendall((s + "\r\n").encode())
        send("220 Test explicit FTPS")
        buf = b""; cwd = "/"; tls = False; prot = False; ok = False; user = None; pasv = None
        def readline():
            nonlocal buf
            while b"\r\n" not in buf:
                d = f.recv(4096)
                if not d: return None
                buf += d
            line, buf = buf.split(b"\r\n", 1); return line.decode()
        while True:
            line = readline()
            if line is None: break
            cmd, _, arg = line.partition(" "); cmd = cmd.upper()
            log.write("TLS " if tls else "CLEAR "); log.write(("PASS" if cmd == "PASS" else line) + "\n")
            if cmd == "AUTH":
                send("234 Proceed"); f = ctx.wrap_socket(c, server_side=True); tls = True; buf = b""
            elif cmd == "USER": user = arg; send("331 Password required")
            elif cmd == "PASS":
                if tls and user == "ola" and arg == "tajne-haslo-ftps-123": ok = True; send("230 Logged in")
                else: send("530 Login incorrect")
            elif cmd in ("PBSZ",): send("200 PBSZ=0")
            elif cmd == "PROT": prot = (arg.upper() == "P"); send("200 Protection set")
            elif cmd == "FEAT": send("211-Features:"); send(" UTF8"); send(" EPSV"); send(" MLSD"); send(" PBSZ"); send(" PROT"); send("211 End")
            elif cmd in ("SYST",): send("215 UNIX Type: L8")
            elif cmd in ("OPTS", "TYPE"): send("200 OK")
            elif not ok: send("530 Please login")
            elif cmd == "PWD": send('257 "%s" is current directory' % cwd)
            elif cmd == "CWD":
                parts, p = real(cwd, arg)
                if os.path.isdir(p): cwd = "/" + "/".join(parts); send("250 OK")
                else: send("550 No such directory")
            elif cmd == "EPSV":
                if pasv: pasv.close()
                pasv = socket.socket(); pasv.bind(("127.0.0.1", 0)); pasv.listen(1)
                send("229 Entering Extended Passive Mode (|||%d|)" % pasv.getsockname()[1])
            elif cmd in ("MLSD", "LIST", "RETR", "STOR"):
                parts, p = real(cwd, arg if arg else ".")
                if cmd in ("MLSD", "LIST") and not os.path.isdir(p): send("550 No such directory"); continue
                if cmd == "RETR" and not os.path.isfile(p): send("550 No such file"); continue
                send("150 Opening data connection")
                d, _ = pasv.accept(); pasv.close(); pasv = None
                if prot: d = ctx.wrap_socket(d, server_side=True)
                if cmd == "MLSD":
                    out = ""
                    for n in sorted(os.listdir(p)):
                        q = os.path.join(p, n); isd = os.path.isdir(q)
                        out += "type=%s;size=%d;modify=20251014120000; %s\r\n" % ("dir" if isd else "file", 0 if isd else os.path.getsize(q), n)
                    d.sendall(out.encode()); d.close()
                elif cmd == "LIST": d.close()
                elif cmd == "RETR":
                    d.sendall(open(p, "rb").read()); d.close()
                else:
                    data = b""
                    while True:
                        chunk = d.recv(65536)
                        if not chunk: break
                        data += chunk
                    open(p, "wb").write(data); d.close()
                send("226 Transfer complete")
            elif cmd == "QUIT": send("221 Bye"); break
            else: send("502 Not implemented")
        try: c.close()
        except Exception: pass
    while True:
        c, _ = srv.accept()
        threading.Thread(target=lambda c=c: session(c), daemon=True).start()
    """#

    private func startServer(_ tls: TestTLS) throws -> (port: Int, log: URL) {
        let py = dir.appendingPathComponent("srv.py"); try Self.script.write(to: py, atomically: true, encoding: .utf8)
        let log = dir.appendingPathComponent("cmds.log"); FileManager.default.createFile(atPath: log.path, contents: nil)
        let keyPath = tls.certPEM.path.replacingOccurrences(of: "/c-", with: "/k-")
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-I", py.path, root.path, tls.certPEM.path, keyPath, log.path]
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        try XCTSkipIf(!FileManager.default.isExecutableFile(atPath: "/usr/bin/python3"), "brak python3")
        try p.run(); proc = p
        let line = String(decoding: out.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = Int(line) else { throw XCTSkip("serwer Pythona nie wystartował: \(line)") }
        return (port, log)
    }

    private func ctx() -> ProviderContext {
        ProviderContext(credentials: ConnectionCredentials(password: "tajne-haslo-ftps-123"),
                        hostKeyVerifier: HostKeyVerifier(store: TrustedHostsStore(url: dir.appendingPathComponent("h.json"))) { _ in false })
    }

    func testExplicitFTPSUpgradesBeforeCredentialsAndTransfersOverTLS() async throws {
        let tls = try TestTLS.make(in: dir)
        let (port, log) = try startServer(tls)
        try "jawny TLS".write(to: root.appendingPathComponent("plik ą.txt"), atomically: true, encoding: .utf8)
        let profile = ConnectionProfile(name: "x", proto: .ftps, host: "127.0.0.1", port: port, username: "ola", initialPath: "", ftpsMode: .explicit, connectTimeoutSeconds: 5)
        let p = try FTPProvider(profile: profile, context: ctx(), trustedCA: tls.certPEM)
        try await p.connect(); defer { Task { await p.disconnect() } }
        let names = try await p.list(.root).map(\.name)
        XCTAssertEqual(names, ["plik ą.txt"])
        let dst = dir.appendingPathComponent("o.txt")
        try await p.download(RemotePath(parsing: "/plik ą.txt"), to: dst) { _ in }
        XCTAssertEqual(try String(contentsOf: dst), "jawny TLS")
        let src = dir.appendingPathComponent("w.txt"); try "wysłane".write(to: src, atomically: true, encoding: .utf8)
        try await p.upload(from: src, to: RemotePath(parsing: "/w.txt"), overwrite: false) { _ in }
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("w.txt")), "wysłane")

        let lines = try String(contentsOf: log).split(separator: "\n").map(String.init)
        let authIndex = try XCTUnwrap(lines.firstIndex { $0.hasSuffix("AUTH TLS") }, "log serwera: \(lines)")
        let userIndex = try XCTUnwrap(lines.firstIndex { $0.contains("USER") })
        XCTAssertLessThan(authIndex, userIndex, "AUTH TLS przed logowaniem")
        XCTAssertTrue(lines.filter { $0.contains("USER") || $0.hasSuffix("PASS") }.allSatisfy { $0.hasPrefix("TLS ") }, "dane logowania wyłącznie w kanale TLS")
        XCTAssertTrue(lines.contains { $0.contains("PROT P") }, "kanał danych też chroniony")
    }
}
