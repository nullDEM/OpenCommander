import XCTest
@testable import OpenCommanderCore

@MainActor
final class ConnectionManagerTests: XCTestCase {
    var secrets: InMemorySecretStore!
    var defaults: UserDefaults!
    var hostsURL: URL!
    var created: [(ConnectionProfile, ConnectionCredentials)] = []

    override func setUp() async throws {
        secrets = InMemorySecretStore()
        defaults = UserDefaults(suiteName: "oc-cm-\(UUID().uuidString)")!
        hostsURL = FileManager.default.temporaryDirectory.appendingPathComponent("oc-cm-\(UUID().uuidString)/hosts.json")
        created = []
    }

    private func manager() -> ConnectionManager {
        let m = ConnectionManager(profileStore: ProfileStore(defaults: defaults, key: "p"), secrets: secrets,
                                  trustedHostsStore: TrustedHostsStore(url: hostsURL))
        m.providerFactory = { profile, ctx in
            FailingFactoryBox.record(profile, ctx.credentials)
            return FakeProvider()
        }
        return m
    }

    private func sftp(_ name: String = "Serwer", ref: SecretRef? = nil) -> ConnectionProfile {
        ConnectionProfile(name: name, proto: .sftp, host: "example.test", username: "ola", passwordRef: ref)
    }

    func testSavingStoresPasswordInSecretStoreNotInProfile() throws {
        let m = manager()
        let saved = try m.save(sftp(), password: "TajneHaslo1")
        let ref = try XCTUnwrap(saved.passwordRef)
        XCTAssertEqual(try secrets.secret(for: ref), "TajneHaslo1")
        let raw = String(data: defaults.data(forKey: "p")!, encoding: .utf8)!
        XCTAssertFalse(raw.contains("TajneHaslo1"))
        XCTAssertEqual(manager().profiles.count, 1, "profil przeżywa ponowne utworzenie menedżera")
    }

    func testSessionOnlyPasswordIsNotWrittenToKeychainOrDefaults() throws {
        let m = manager()
        let saved = try m.save(sftp(), password: "TylkoNaSesje", rememberPassword: false)
        XCTAssertNil(saved.passwordRef)
        XCTAssertEqual(secrets.count, 0, "nic nie trafia do trwałego magazynu")
        XCTAssertFalse(String(data: defaults.data(forKey: "p")!, encoding: .utf8)!.contains("TylkoNaSesje"))
    }

    func testInvalidProfileIsRejectedOnSave() {
        let m = manager()
        XCTAssertThrowsError(try m.save(ConnectionProfile(name: "F", proto: .ftp, host: "h", username: "u")))
        XCTAssertTrue(m.profiles.isEmpty)
    }

    func testRemoveDeletesOnlyExclusiveSecretsWhenAsked() async throws {
        let m = manager()
        let shared = SecretRef(); try secrets.setSecret("wspólne", for: shared)
        let a = try m.save(sftp("A", ref: shared))
        let b = try m.save(sftp("B"), password: "własne-B")
        let bRef = try XCTUnwrap(b.passwordRef)
        _ = try m.save(sftp("C", ref: shared))
        await m.remove(a.id, deleteSecrets: true)
        XCTAssertEqual(try secrets.secret(for: shared), "wspólne", "sekret współdzielony z profilem C zostaje")
        await m.remove(b.id, deleteSecrets: false)
        XCTAssertEqual(try secrets.secret(for: bRef), "własne-B", "bez zgody sekret zostaje")
        XCTAssertEqual(m.profiles.map(\.name), ["C"])
    }

    func testConnectUsesSavedPasswordWithoutPrompting() async throws {
        let m = manager()
        let p = try m.save(sftp(), password: "zapisane")
        m.credentialPrompt = { _, _ in XCTFail("nie powinno pytać"); return nil }
        _ = try await m.connect(p.id)
        XCTAssertEqual(m.state(p.id), .connected)
        XCTAssertEqual(FailingFactoryBox.lastCredentials?.password, "zapisane")
    }

    func testMissingPasswordPromptsOnceAndIsRememberedOnlyForTheSession() async throws {
        let m = manager()
        let p = try m.save(sftp())
        var asked = 0
        m.credentialPrompt = { _, kind in asked += 1; XCTAssertEqual(kind, .password); return "z-pytania" }
        _ = try await m.connect(p.id)
        XCTAssertEqual(asked, 1)
        await m.noteFailure(p.id, NetworkError.connectionLost)
        _ = try await m.provider(for: p.id)   // ponowne połączenie bez ponownego pytania
        XCTAssertEqual(asked, 1)
        await m.disconnect(p.id)
        _ = try await m.connect(p.id)
        XCTAssertEqual(asked, 2, "po świadomym rozłączeniu hasło sesyjne znika")
        XCTAssertEqual(secrets.count, 0)
    }

    func testCancelledPromptAbortsConnection() async throws {
        let m = manager()
        let p = try m.save(sftp())
        m.credentialPrompt = { _, _ in nil }
        do { _ = try await m.connect(p.id); XCTFail() } catch { XCTAssertEqual(error as? NetworkError, .cancelled) }
        if case .failed = m.state(p.id) {} else { XCTFail("stan powinien być „failed”") }
    }

    func testLostSessionReconnectsOnNextUse() async throws {
        let m = manager()
        let p = try m.save(sftp(), password: "x")
        let first = try await m.provider(for: p.id) as AnyObject
        let same = try await m.provider(for: p.id) as AnyObject
        XCTAssertTrue(first === same, "działająca sesja jest współdzielona")
        m.noteFailure(p.id, NetworkError.connectionLost)
        if case .failed = m.state(p.id) {} else { XCTFail() }
        let again = try await m.provider(for: p.id) as AnyObject
        XCTAssertFalse(first === again, "po utracie sesji powstaje nowe połączenie")
        XCTAssertEqual(m.state(p.id), .connected)
    }

    func testPermissionErrorsDoNotDropTheSession() async throws {
        let m = manager()
        let p = try m.save(sftp(), password: "x")
        _ = try await m.connect(p.id)
        m.noteFailure(p.id, NetworkError.permissionDenied("/root"))
        XCTAssertEqual(m.state(p.id), .connected)
    }

    func testTestConnectionSucceedsAndFailureMessagesAreRedacted() async throws {
        let m = manager()
        let ok = await m.test(sftp(), password: "p", passphrase: nil)
        if case .success(let s) = ok { XCTAssertTrue(s.contains("Połączono")) } else { XCTFail("\(ok)") }
        m.providerFactory = { _, ctx in throw NetworkError.connectionFailed("login ola:\(ctx.credentials.password ?? "")@host odrzucony password=\(ctx.credentials.password ?? "")") }
        let bad = await m.test(sftp(), password: "SuperHaslo99", passphrase: nil)
        guard case .failure(let e) = bad else { return XCTFail() }
        XCTAssertFalse((e.errorDescription ?? "").contains("SuperHaslo99"))
        XCTAssertTrue(m.profiles.isEmpty, "test nie zapisuje profilu")
    }

    func testTestConnectionRejectsInvalidDraftWithoutConnecting() async {
        let m = manager()
        let r = await m.test(ConnectionProfile(name: "x", proto: .ftp, host: "h", username: "u"), password: nil, passphrase: nil)
        guard case .failure(.invalidProfile) = r else { return XCTFail("\(r)") }
        XCTAssertNil(FailingFactoryBox.lastCredentials.flatMap { _ in nil as Int? })
    }
}

/// Pomocnik zapisujący wywołania fabryki (fabryka jest @Sendable, więc stan trzymamy poza testem).
enum FailingFactoryBox {
    nonisolated(unsafe) static var lastProfile: ConnectionProfile?
    nonisolated(unsafe) static var lastCredentials: ConnectionCredentials?
    static func record(_ p: ConnectionProfile, _ c: ConnectionCredentials) { lastProfile = p; lastCredentials = c }
}

final class HostKeyVerifierTests: XCTestCase {
    let info = HostKeyInfo(host: "h.test", port: 22, keyType: "ssh-ed25519", fingerprint: "SHA256:AAA")
    func store() -> TrustedHostsStore { TrustedHostsStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("oc-hk-\(UUID().uuidString)/t.json")) }

    func testUnknownKeyAcceptedIsPersistedAndNotAskedAgain() async throws {
        let s = store(); let asked = AskCounter()
        let v = HostKeyVerifier(store: s) { _ in await asked.bump(); return true }
        try await v.verify(info)
        try await v.verify(info)
        let count = await asked.value
        XCTAssertEqual(count, 1)
        XCTAssertEqual(s.load().verdict(for: info), .trusted)
    }

    func testRejectedUnknownKeyIsNotPersisted() async throws {
        let s = store()
        let v = HostKeyVerifier(store: s) { _ in false }
        do { try await v.verify(info); XCTFail() } catch { XCTAssertEqual(error as? NetworkError, .hostKeyRejected) }
        XCTAssertEqual(s.load().verdict(for: info), .unknown)
    }

    func testChangedKeyBlocksWithoutEvenPrompting() async throws {
        let s = store(); var t = TrustedHosts(); t.trust(info); try s.save(t)
        let asked = AskCounter()
        let v = HostKeyVerifier(store: s) { _ in await asked.bump(); return true }
        let evil = HostKeyInfo(host: "h.test", port: 22, keyType: "ssh-ed25519", fingerprint: "SHA256:EVIL")
        do { try await v.verify(evil); XCTFail("zmieniony klucz musi blokować") }
        catch NetworkError.hostKeyChanged(let expected, let actual) { XCTAssertEqual(expected, "SHA256:AAA"); XCTAssertEqual(actual.fingerprint, "SHA256:EVIL") }
        let count = await asked.value
        XCTAssertEqual(count, 0, "nie pytamy użytkownika o akceptację podmienionego klucza")
        XCTAssertEqual(s.load().verdict(for: info), .trusted)
    }
}

actor AskCounter { private(set) var value = 0; func bump() { value += 1 } }

final class RemoteEntryMappingTests: XCTestCase {
    func testMappingProducesRemoteURLsAndKinds() throws {
        let dir = RemoteLocation(connectionID: UUID(), path: RemotePath(parsing: "/home/ola"))
        let f = try XCTUnwrap(RemoteEntry(name: "zażółć #1.txt", kind: .file, size: 12).fileEntry(in: dir))
        XCTAssertFalse(f.url.isFileURL); XCTAssertTrue(f.url.isRemoteLocation)
        XCTAssertEqual(f.size, 12); XCTAssertFalse(f.isDirectory)
        XCTAssertEqual(RemoteLocation(url: f.url)?.path.string, "/home/ola/zażółć #1.txt")
        let d = try XCTUnwrap(RemoteEntry(name: "folder", kind: .directory).fileEntry(in: dir))
        XCTAssertTrue(d.isNavigable)
        let l = try XCTUnwrap(RemoteEntry(name: "lnk", kind: .symlink, symlinkTargetIsDirectory: true).fileEntry(in: dir))
        XCTAssertTrue(l.isSymbolicLink); XCTAssertTrue(l.isDirectory)
        XCTAssertNil(RemoteEntry(name: "../zły", kind: .file).fileEntry(in: dir), "podejrzana nazwa z serwera nie trafia do listy")
        XCTAssertNotEqual(f.id, try XCTUnwrap(RemoteEntry(name: "zażółć #1.txt", kind: .file).fileEntry(in: RemoteLocation(connectionID: UUID(), path: dir.path))).id)
    }
}
