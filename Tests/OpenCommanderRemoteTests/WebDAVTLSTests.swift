import XCTest
import Network
import Security
@testable import OpenCommanderRemote
@testable import OpenCommanderCore

/// HTTPS z certyfikatem samopodpisanym (wygenerowanym na czas testu w katalogu tymczasowym): klient musi odmówić.
final class WebDAVTLSTests: XCTestCase {
    var dir: URL!

    override func setUp() async throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().appendingPathComponent("oc-tls-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    private func run(_ args: [String]) throws {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl"); p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        try p.run(); p.waitUntilExit()
        try XCTSkipIf(p.terminationStatus != 0, "openssl niedostępny lub zawiódł")
    }

    private func tlsParameters() throws -> NWParameters {
        let key = dir.appendingPathComponent("k.pem").path, crt = dir.appendingPathComponent("c.pem").path, p12 = dir.appendingPathComponent("s.p12").path
        try run(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", crt, "-days", "1", "-subj", "/CN=127.0.0.1",
                 "-addext", "subjectAltName=IP:127.0.0.1"])
        try run(["pkcs12", "-export", "-inkey", key, "-in", crt, "-out", p12, "-passout", "pass:test"])
        let data = try Data(contentsOf: URL(fileURLWithPath: p12))
        var items: CFArray?
        let st = SecPKCS12Import(data as CFData, [kSecImportExportPassphrase as String: "test"] as CFDictionary, &items)
        try XCTSkipIf(st != errSecSuccess, "import PKCS12 nie powiódł się (\(st))")
        let identity = ((items as? [[String: Any]])?.first?[kSecImportItemIdentity as String]).map { $0 as! SecIdentity }
        let id = try XCTUnwrap(identity)
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, sec_identity_create(id)!)
        return NWParameters(tls: tls)
    }

    func testSelfSignedCertificateIsRejectedAndNothingIsSent() async throws {
        let root = dir.appendingPathComponent("srv"); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let server = try await TestDAVServer.start(root: root, tls: try tlsParameters()); defer { server.stop() }
        let profile = ConnectionProfile(name: "tls", proto: .webdav, username: server.username, baseURL: "https://127.0.0.1:\(server.port)/", connectTimeoutSeconds: 10)
        let ctx = ProviderContext(credentials: ConnectionCredentials(password: server.password),
                                  hostKeyVerifier: HostKeyVerifier(store: TrustedHostsStore(url: dir.appendingPathComponent("h.json"))) { _ in false })
        let p = try WebDAVProvider(profile: profile, context: ctx)
        do { try await p.connect(); XCTFail("certyfikat samopodpisany musi zostać odrzucony") }
        catch let e as NetworkError {
            if case .tlsCertificateInvalid = e {} else { XCTFail("oczekiwano błędu certyfikatu, jest: \(e)") }
            XCTAssertFalse(e.localizedDescription.contains(server.password))
        }
        XCTAssertTrue(server.requests.isEmpty, "żadne żądanie HTTP (ani hasło) nie dotarło do serwera z nieprawidłowym certyfikatem")
    }
}
