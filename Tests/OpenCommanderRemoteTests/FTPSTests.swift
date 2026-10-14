import XCTest
@testable import OpenCommanderRemote
@testable import OpenCommanderCore

/// FTPS niejawny (TLS od pierwszego bajtu) na serwerze z samopodpisanym certyfikatem testowym.
/// Zaufanie: certyfikat testowy jest jedynym zaufanym korzeniem dla danego połączenia (CURLOPT_CAINFO) — weryfikacja nie jest wyłączona.
final class FTPSTests: XCTestCase {
    var dir: URL!, root: URL!

    override func setUp() async throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().appendingPathComponent("oc-ftps-\(UUID().uuidString)")
        root = dir.appendingPathComponent("srv")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    private func ctx(_ pw: String) -> ProviderContext {
        ProviderContext(credentials: ConnectionCredentials(password: pw),
                        hostKeyVerifier: HostKeyVerifier(store: TrustedHostsStore(url: dir.appendingPathComponent("h.json"))) { _ in false })
    }
    private func profile(port: Int, host: String = "127.0.0.1", user: String) -> ConnectionProfile {
        ConnectionProfile(name: "ftps", proto: .ftps, host: host, port: port, username: user, initialPath: "", ftpsMode: .implicit, connectTimeoutSeconds: 5)
    }

    func testImplicitFTPSWorksWhenCertificateIsTrusted() async throws {
        let tls = try TestTLS.make(in: dir)
        let server = try await TestFTPServer.start(root: root, tls: tls.parameters); defer { server.stop() }
        try "szyfrowane".write(to: root.appendingPathComponent("tajny ą.txt"), atomically: true, encoding: .utf8)
        let p = try FTPProvider(profile: profile(port: server.port, user: server.username), context: ctx(server.password), trustedCA: tls.certPEM)
        try await p.connect(); defer { Task { await p.disconnect() } }
        let list = try await p.list(.root)
        XCTAssertEqual(list.map(\.name), ["tajny ą.txt"])
        let dst = dir.appendingPathComponent("pobrany.txt")
        try await p.download(RemotePath(parsing: "/tajny ą.txt"), to: dst) { _ in }
        XCTAssertEqual(try String(contentsOf: dst), "szyfrowane")
        let src = dir.appendingPathComponent("w.txt"); try "wysyłane".write(to: src, atomically: true, encoding: .utf8)
        try await p.upload(from: src, to: RemotePath(parsing: "/w.txt"), overwrite: false) { _ in }
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("w.txt")), "wysyłane")
        XCTAssertTrue(server.commands.contains("PROT P") || server.commands.contains { $0.hasPrefix("PROT") }, "kanał danych też jest chroniony (PROT)")
    }

    func testUntrustedSelfSignedCertificateIsRejectedAndNoCredentialsAreSent() async throws {
        let tls = try TestTLS.make(in: dir)
        let server = try await TestFTPServer.start(root: root, tls: tls.parameters); defer { server.stop() }
        // bez `trustedCA`: certyfikat samopodpisany nie jest w systemowych korzeniach
        let p = try FTPProvider(profile: profile(port: server.port, user: server.username), context: ctx(server.password))
        do { try await p.connect(); XCTFail("niezaufany certyfikat musi zostać odrzucony") }
        catch let e as NetworkError { if case .tlsCertificateInvalid = e {} else { XCTFail("\(e)") }; XCTAssertFalse(e.localizedDescription.contains(server.password)) }
        XCTAssertFalse(server.commands.contains("PASS"), "hasło nie dotarło do serwera z niezaufanym certyfikatem")
    }

    func testHostnameMismatchIsRejectedEvenWithTrustedCA() async throws {
        // certyfikat wystawiony dla innej nazwy niż adres, z którym się łączymy
        let tls = try TestTLS.make(in: dir, commonName: "inny.example.test", san: "DNS:inny.example.test")
        let server = try await TestFTPServer.start(root: root, tls: tls.parameters); defer { server.stop() }
        let p = try FTPProvider(profile: profile(port: server.port, user: server.username), context: ctx(server.password), trustedCA: tls.certPEM)
        do { try await p.connect(); XCTFail("nazwa hosta nie pasuje do certyfikatu") }
        catch let e as NetworkError { if case .tlsCertificateInvalid = e {} else { XCTFail("\(e)") } }
        XCTAssertFalse(server.commands.contains("PASS"))
    }
}
