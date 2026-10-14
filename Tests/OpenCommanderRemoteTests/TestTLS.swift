import XCTest
import Network
import Security
import OpenCommanderCore

/// Samopodpisany certyfikat dla 127.0.0.1 wygenerowany w katalogu tymczasowym (openssl z systemu) — wyłącznie do testów.
struct TestTLS {
    let certPEM: URL
    let parameters: NWParameters

    static func make(in dir: URL, commonName: String = "127.0.0.1", san: String = "IP:127.0.0.1") throws -> TestTLS {
        func run(_ args: [String]) throws {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl"); p.arguments = args
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
            try p.run(); p.waitUntilExit()
            try XCTSkipIf(p.terminationStatus != 0, "openssl niedostępny lub zawiódł")
        }
        let key = dir.appendingPathComponent("k-\(commonName.hashValue).pem").path
        let crt = dir.appendingPathComponent("c-\(commonName.hashValue).pem")
        let p12 = dir.appendingPathComponent("s-\(commonName.hashValue).p12").path
        try run(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", crt.path, "-days", "1",
                 "-subj", "/CN=\(commonName)", "-addext", "subjectAltName=\(san)"])
        try run(["pkcs12", "-export", "-inkey", key, "-in", crt.path, "-out", p12, "-passout", "pass:test"])
        var items: CFArray?
        let st = SecPKCS12Import(try Data(contentsOf: URL(fileURLWithPath: p12)) as CFData, [kSecImportExportPassphrase as String: "test"] as CFDictionary, &items)
        try XCTSkipIf(st != errSecSuccess, "import PKCS12 nie powiódł się (\(st))")
        let identity = try XCTUnwrap(((items as? [[String: Any]])?.first?[kSecImportItemIdentity as String]).map { $0 as! SecIdentity })
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, sec_identity_create(identity)!)
        return TestTLS(certPEM: crt, parameters: NWParameters(tls: tls))
    }
}
