import XCTest
@testable import OpenCommanderCore

final class RemotePathTests: XCTestCase {
    func testParsingNormalizesAndNeverEscapesRoot() {
        XCTAssertEqual(RemotePath(parsing: "/a//b/./c").string, "/a/b/c")
        XCTAssertEqual(RemotePath(parsing: "a/b/../c").string, "/a/c")
        XCTAssertEqual(RemotePath(parsing: "/../../etc").string, "/etc")
        XCTAssertEqual(RemotePath(parsing: "").string, "/")
        XCTAssertTrue(RemotePath(parsing: "/..").isRoot)
        XCTAssertEqual(RemotePath(parsing: "/a/b").parent.string, "/a")
        XCTAssertTrue(RemotePath.root.parent.isRoot)
    }

    func testAppendingRejectsSeparatorsAndDots() {
        let base = RemotePath(parsing: "/srv")
        for bad in ["", ".", "..", "a/b", "a\0b", "/"] {
            XCTAssertThrowsError(try base.appending(bad), "„\(bad)” powinno być odrzucone")
        }
        XCTAssertEqual(try base.appending("plik.txt").string, "/srv/plik.txt")
    }

    func testLocationURLRoundTripWithSpecialCharacters() throws {
        let id = UUID()
        let names = ["zwykły", "ze spacją", "a#b", "100%", "co?kolwiek", "a&b=c", "Żółć ĄĘ 日本", "plus+znak", "ma;srednik", "nawias(1)", "😀 emoji"]
        for n in names {
            let loc = RemoteLocation(connectionID: id, path: try RemotePath.root.appending("katalog").appending(n))
            let url = loc.url
            XCTAssertEqual(url.scheme, "ocremote")
            XCTAssertNil(url.fragment, "„#” w nazwie nie może stać się fragmentem URL: \(n)")
            XCTAssertNil(url.query, "„?” w nazwie nie może stać się zapytaniem: \(n)")
            XCTAssertEqual(RemoteLocation(url: url), loc, "round-trip nie zachował „\(n)”")
        }
    }

    func testSeparatorsAreNotEncodedButNameCharactersAre() throws {
        let loc = RemoteLocation(connectionID: UUID(), path: try RemotePath.root.appending("a b").appending("c#d"))
        XCTAssertTrue(loc.url.absoluteString.hasSuffix("/a%20b/c%23d"))
    }

    func testRemoteURLIsNeverAFileURLAndDistinctPerConnection() {
        let a = RemoteLocation(connectionID: UUID(), path: RemotePath(parsing: "/home"))
        let b = RemoteLocation(connectionID: UUID(), path: RemotePath(parsing: "/home"))
        XCTAssertFalse(a.url.isFileURL)
        XCTAssertTrue(a.url.isRemoteLocation)
        XCTAssertNotEqual(a.url, b.url, "ta sama ścieżka na dwóch serwerach to dwie różne tożsamości")
        XCTAssertNil(RemoteLocation(url: URL(fileURLWithPath: "/home")))
        XCTAssertNil(RemoteLocation(url: URL(string: "ocremote://nie-uuid/x")!))
    }

    func testMaliciousEncodedTraversalInURLIsRejected() {
        let id = UUID().uuidString.lowercased()
        XCTAssertNil(RemoteLocation(url: URL(string: "ocremote://\(id)/a/%2e%2e/b")!))
        XCTAssertNil(RemoteLocation(url: URL(string: "ocremote://\(id)/a%2Fb")!))
    }

    func testLocalMappingBlocksTraversalNames() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oc-map-\(UUID().uuidString)")
        for evil in ["..", "../x", "a/../../x", "/etc/passwd", "", ".", "a/b", "x\0y"] {
            XCTAssertNil(LocalMapping.url(for: evil, in: root), "„\(evil)” musi być zablokowane")
        }
        XCTAssertNotNil(LocalMapping.url(for: "ok.txt", in: root))
        XCTAssertNotNil(LocalMapping.url(for: "..hidden", in: root), "nazwa zaczynająca się od kropek, ale nie „..”, jest poprawna")
    }
}

final class ConnectionProfileTests: XCTestCase {
    private func sftp(_ mutate: (inout ConnectionProfile) -> Void = { _ in }) -> ConnectionProfile {
        var p = ConnectionProfile(name: "Serwer", proto: .sftp, host: "example.test", username: "ola")
        mutate(&p); return p
    }

    func testValidProfilesPass() {
        XCTAssertNil(sftp().validationError())
        XCTAssertNil(ConnectionProfile(name: "F", proto: .ftps, host: "ftp.test", username: "u").validationError())
        XCTAssertNil(ConnectionProfile(name: "W", proto: .webdav, username: "u", baseURL: "https://dav.test/remote.php/webdav/", auth: .password).validationError())
    }

    func testPlainFTPAndHTTPRequireExplicitConsent() {
        var ftp = ConnectionProfile(name: "F", proto: .ftp, host: "ftp.test", username: "u")
        XCTAssertNotNil(ftp.validationError())
        ftp.allowInsecure = true
        XCTAssertNil(ftp.validationError())
        var dav = ConnectionProfile(name: "W", proto: .webdav, username: "u", baseURL: "http://dav.test/")
        XCTAssertNotNil(dav.validationError())
        dav.allowInsecure = true
        XCTAssertNil(dav.validationError())
        XCTAssertFalse(dav.isEncrypted); XCTAssertFalse(ftp.isEncrypted)
        XCTAssertTrue(ConnectionProfile(name: "F", proto: .ftps, host: "h", username: "u").isEncrypted)
    }

    func testRejectsCredentialsEmbeddedInURLAndBadHosts() {
        let dav = ConnectionProfile(name: "W", proto: .webdav, username: "u", baseURL: "https://ola:tajne@dav.test/")
        XCTAssertNotNil(dav.validationError())
        for host in ["", "a b", "host/path", "user@host", "ho#st"] {
            XCTAssertNotNil(sftp { $0.host = host }.validationError(), "host „\(host)” powinien być odrzucony")
        }
        XCTAssertNotNil(sftp { $0.port = 0 }.validationError())
        XCTAssertNotNil(sftp { $0.port = 70000 }.validationError())
        XCTAssertNotNil(sftp { $0.name = "  " }.validationError())
        XCTAssertNotNil(sftp { $0.auth = .anonymous }.validationError())
        XCTAssertNotNil(sftp { $0.auth = .privateKey }.validationError(), "klucz wymaga ścieżki pliku")
        XCTAssertNil(sftp { $0.auth = .privateKey; $0.keyFilePath = "/tmp/klucz" }.validationError())
    }

    func testDefaultPorts() {
        XCTAssertEqual(ConnectionProfile.defaultPort(.sftp), 22)
        XCTAssertEqual(ConnectionProfile.defaultPort(.ftp), 21)
        XCTAssertEqual(ConnectionProfile.defaultPort(.ftps, ftpsMode: .explicit), 21)
        XCTAssertEqual(ConnectionProfile.defaultPort(.ftps, ftpsMode: .implicit), 990)
        XCTAssertEqual(ConnectionProfile.defaultPort(.webdav, baseURL: "http://x/"), 80)
        XCTAssertEqual(ConnectionProfile.defaultPort(.webdav, baseURL: "https://x/"), 443)
    }

    func testStoredProfilesContainNoSecrets() throws {
        let defaults = UserDefaults(suiteName: "oc-test-\(UUID().uuidString)")!
        let store = ProfileStore(defaults: defaults, key: "k")
        let secrets = InMemorySecretStore()
        let ref = SecretRef(); let pref = SecretRef()
        try secrets.setSecret("SuperTajneHaslo123", for: ref)
        try secrets.setSecret("FrazaKlucza456", for: pref)
        let p = ConnectionProfile(name: "Prod", proto: .sftp, host: "example.test", username: "ola", auth: .privateKey,
                                  keyFilePath: "/Users/x/.ssh/id_ed25519", passwordRef: ref, passphraseRef: pref)
        store.save([p])
        let raw = String(data: defaults.data(forKey: "k")!, encoding: .utf8)!
        XCTAssertFalse(raw.contains("SuperTajneHaslo123"))
        XCTAssertFalse(raw.contains("FrazaKlucza456"))
        XCTAssertFalse(raw.lowercased().contains("begin openssh private key"))
        XCTAssertTrue(raw.contains(ref.id.uuidString), "profil trzyma tylko odwołanie do Keychain")
        XCTAssertEqual(store.load(), [p])
    }

    func testDeletingProfileKeepsSharedSecrets() {
        let shared = SecretRef(), own = SecretRef()
        let a = ConnectionProfile(name: "A", proto: .sftp, host: "h", username: "u", passwordRef: shared, passphraseRef: own)
        let b = ConnectionProfile(name: "B", proto: .sftp, host: "h2", username: "u", passwordRef: shared)
        let removable = ProfileStore.exclusiveSecretRefs(of: a, among: [a, b])
        XCTAssertEqual(removable, [own], "współdzielony sekret zostaje, bo używa go profil B")
        XCTAssertEqual(Set(ProfileStore.exclusiveSecretRefs(of: b, among: [b])), [shared])
    }
}

final class SecretStoreTests: XCTestCase {
    func testInMemoryRoundTripAndDelete() throws {
        let s = InMemorySecretStore(); let r = SecretRef()
        XCTAssertNil(try s.secret(for: r))
        try s.setSecret("a", for: r); XCTAssertEqual(try s.secret(for: r), "a")
        try s.setSecret("b", for: r); XCTAssertEqual(try s.secret(for: r), "b")
        try s.deleteSecret(for: r); XCTAssertNil(try s.secret(for: r))
        XCTAssertNoThrow(try s.deleteSecret(for: r), "usunięcie nieistniejącego nie jest błędem")
    }

    func testKeychainQueryDoesNotLeakServerOrSyncToCloud() {
        let store = KeychainSecretStore(service: "test.service")
        let ref = SecretRef()
        let q = store.baseQuery(ref)
        XCTAssertEqual(q[kSecAttrAccount as String] as? String, ref.id.uuidString)
        XCTAssertEqual(q[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertEqual(q[kSecAttrService as String] as? String, "test.service")
    }
}

final class TrustedHostsTests: XCTestCase {
    let info = HostKeyInfo(host: "Example.Test", port: 22, keyType: "ssh-ed25519", fingerprint: "SHA256:AAAA")

    func testUnknownThenTrustedThenChangedBlocks() {
        var t = TrustedHosts()
        XCTAssertEqual(t.verdict(for: info), .unknown)
        XCTAssertTrue(t.trust(info))
        XCTAssertEqual(t.verdict(for: info), .trusted)
        let changed = HostKeyInfo(host: "example.test", port: 22, keyType: "ssh-ed25519", fingerprint: "SHA256:BBBB")
        XCTAssertEqual(t.verdict(for: changed), .changed(expected: "SHA256:AAAA"))
        XCTAssertFalse(t.trust(changed), "zmieniony klucz nie jest akceptowany automatycznie")
        XCTAssertEqual(t.verdict(for: info), .trusted, "stare zaufanie nietknięte")
    }

    func testDifferentKeyTypeForKnownHostCountsAsChange() {
        var t = TrustedHosts(); t.trust(info)
        let rsa = HostKeyInfo(host: "example.test", port: 22, keyType: "ssh-rsa", fingerprint: "SHA256:CCCC")
        XCTAssertEqual(t.verdict(for: rsa), .changed(expected: "SHA256:AAAA"))
    }

    func testPortIsPartOfIdentityAndRemovalWorks() {
        var t = TrustedHosts(); t.trust(info)
        let other = HostKeyInfo(host: "example.test", port: 2222, keyType: "ssh-ed25519", fingerprint: "SHA256:ZZZZ")
        XCTAssertEqual(t.verdict(for: other), .unknown)
        t.removeAll(host: "EXAMPLE.test", port: 22)
        XCTAssertEqual(t.verdict(for: info), .unknown)
    }

    func testPersistenceRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("oc-th-\(UUID().uuidString)/t.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = TrustedHostsStore(url: url)
        XCTAssertTrue(store.load().entries.isEmpty)
        var t = TrustedHosts(); t.trust(info)
        try store.save(t)
        XCTAssertEqual(store.load().verdict(for: info), .trusted)
    }
}

final class RedactorAndErrorTests: XCTestCase {
    func testRedactsKnownSecretsURLCredentialsHeadersAndKeys() {
        let text = """
        login ftp://ola:Tajne123@host/dir failed; Authorization: Bearer abc.def.ghi
        password=Sekret99&x=1 token=zzzzzz
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAA
        -----END OPENSSH PRIVATE KEY-----
        użyto frazy MojaFraza w kliencie
        """
        let out = Redactor.redact(text, secrets: ["MojaFraza"])
        for leak in ["Tajne123", "Bearer abc", "Sekret99", "zzzzzz", "b3BlbnNzaC1r", "MojaFraza"] {
            XCTAssertFalse(out.contains(leak), "wyciek: \(leak)\n\(out)")
        }
        XCTAssertTrue(out.contains("ftp://ola:•••@host/dir"))
    }

    func testErrorMessagesAreInPolishAndMentionNoSecrets() {
        let errors: [NetworkError] = [.dnsFailure(host: "x.test"), .timeout, .connectionLost, .authenticationFailed,
                                      .hostKeyRejected, .noSpace, .cancelled, .unsupported("rename"),
                                      .hostKeyChanged(expected: "SHA256:A", actual: HostKeyInfo(host: "h", port: 22, keyType: "ssh-rsa", fingerprint: "SHA256:B"))]
        for e in errors { XCTAssertFalse((e.errorDescription ?? "").isEmpty) }
        XCTAssertTrue(NetworkError.hostKeyChanged(expected: "A", actual: HostKeyInfo(host: "h", port: 1, keyType: "t", fingerprint: "B")).errorDescription!.contains("zablokowane"))
    }

    func testOnlyAmbiguousFailuresBlockAutoRetry() {
        XCTAssertTrue(NetworkError.timeout.leavesOutcomeUnknown)
        XCTAssertTrue(NetworkError.connectionLost.leavesOutcomeUnknown)
        XCTAssertFalse(NetworkError.authenticationFailed.leavesOutcomeUnknown)
        XCTAssertFalse(NetworkError.notFound("x").leavesOutcomeUnknown)
    }

    func testNoProviderClaimsResumeByDefault() {
        XCTAssertFalse(ProviderCapabilities().resume, "nie deklarujemy wznowienia, dopóki żaden provider go nie gwarantuje")
    }
}
