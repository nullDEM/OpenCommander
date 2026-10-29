import XCTest
@testable import OpenCommanderCore

final class TrashErrorTests: TempDirTestCase {
    func testPermissionErrorsBecomeAccessDeniedWithHint() {
        let cocoa = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
        let posix = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))])
        for (e, detail) in [(cocoa, "NSCocoaErrorDomain 513"), (posix, "NSCocoaErrorDomain 512, NSPOSIXErrorDomain 1")] {
            let mapped = OperationError.trash(e, name: "IMG.HEIC")
            XCTAssertEqual(mapped, .trashAccessDenied(name: "IMG.HEIC", detail: detail))
            XCTAssertTrue(mapped.localizedDescription.contains(detail), "komunikat podaje kod systemowy")
            XCTAssertTrue(mapped.isAccessDenied)
            XCTAssertTrue(mapped.localizedDescription.contains("Pełny dostęp do dysku"))
        }
    }

    func testOtherTrashErrorsKeepSystemReason() {
        let e = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError, userInfo: [NSLocalizedDescriptionKey: "powód systemowy"])
        let mapped = OperationError.trash(e, name: "a")
        XCTAssertEqual(mapped, .trashFailed(name: "a", reason: "powód systemowy"))
        XCTAssertFalse(mapped.isAccessDenied) // brak miejsca to inny problem niż uprawnienia
    }

    func testEngineReportsAccessDeniedWhenTrashIsRefused() async throws {
        let f = try makeFile("a.txt")
        let t = FakeTrasher(bin: bin); t.shouldFail = true
        let r = await FileOperationEngine(trasher: t).run(FileOperation(kind: .trash, sources: [f]))
        XCTAssertEqual(r.failures.first?.1, .trashAccessDenied(name: "a.txt", detail: "NSCocoaErrorDomain 513"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.path), "plik nietknięty")
    }
}

@MainActor
final class DisconnectDuringConnectTests: XCTestCase {
    func testDisconnectWhileConnectingLeavesSessionDisconnected() async throws {
        for swallows in [false, true] {
            let fake = FakeProvider()
            fake.connectDelay = 0.3
            fake.connectSwallowsCancellation = swallows
            let defaults = UserDefaults(suiteName: "oc-dc-\(UUID().uuidString)")!
            let m = ConnectionManager(profileStore: ProfileStore(defaults: defaults, key: "p"), secrets: InMemorySecretStore(),
                                      trustedHostsStore: TrustedHostsStore(url: FileManager.default.temporaryDirectory
                                        .appendingPathComponent("oc-dc-\(UUID().uuidString)/hosts.json")))
            m.providerFactory = { _, _ in fake }
            let p = try m.save(ConnectionProfile(name: "S", proto: .sftp, host: "example.test", username: "u"), password: "x")

            let connecting = Task { try? await m.connect(p.id) }
            try await Task.sleep(nanoseconds: 100_000_000)
            await m.disconnect(p.id)
            _ = await connecting.value

            XCTAssertEqual(m.state(p.id), .disconnected, "swallows=\(swallows)")
            XCTAssertGreaterThanOrEqual(fake.disconnectCalls, 1, "spóźniony provider musi zostać zamknięty (swallows=\(swallows))")
        }
    }
}

// MARK: - Kolejka pytań (okno pytania musi znikać po odpowiedzi)

@MainActor
final class PromptQueueTests: XCTestCase {
    func testPromptDisappearsAfterAnswer() async throws {
        let q = PromptQueue<String, Bool>()
        let t = Task { await q.ask("klucz") }
        try await waitUntil { q.current != nil }
        XCTAssertEqual(q.current?.info, "klucz")
        q.current?.answer(true)
        let answer = await t.value
        XCTAssertTrue(answer)
        XCTAssertNil(q.current, "po odpowiedzi okno pytania nie może zostać na ekranie")
    }

    func testQueuedPromptsAreShownOneByOneInOrder() async throws {
        let q = PromptQueue<Int, Int>()
        let t1 = Task { await q.ask(1) }
        try await waitUntil { q.current?.info == 1 }
        let t2 = Task { await q.ask(2) }
        let t3 = Task { await q.ask(3) }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(q.current?.info, 1, "kolejne pytania czekają, nie nadpisują bieżącego")

        q.current?.answer(10)
        try await waitUntil { q.current?.info == 2 }
        q.current?.answer(20)
        try await waitUntil { q.current?.info == 3 }
        q.current?.answer(30)
        let results = await (t1.value, t2.value, t3.value)
        XCTAssertEqual([results.0, results.1, results.2], [10, 20, 30], "każde pytanie dostaje własną odpowiedź")
        XCTAssertNil(q.current)
    }

    func testSecondAnswerIsIgnored() async throws {
        let q = PromptQueue<String, String?>()
        let t = Task { await q.ask("hasło") }
        try await waitUntil { q.current != nil }
        let request = try XCTUnwrap(q.current)
        request.answer("pierwsza")
        request.answer("druga")   // nie może się zawiesić ani wznowić ponownie
        let answer = await t.value
        XCTAssertEqual(answer, "pierwsza")
    }

    private func waitUntil(timeout: TimeInterval = 2, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("przekroczono czas oczekiwania"); return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

// MARK: - Nieczytelne dane trwałe nie są po cichu zastępowane

final class UnreadableStoreBackupTests: XCTestCase {
    func testProfileStoreKeepsUnreadableDataBeforeItIsOverwritten() throws {
        let defaults = UserDefaults(suiteName: "oc-bk-\(UUID().uuidString)")!
        let garbage = Data("{\"to jest\": \"inny format\"}".utf8)
        defaults.set(garbage, forKey: "p")
        let store = ProfileStore(defaults: defaults, key: "p")

        XCTAssertTrue(store.load().isEmpty)
        store.save([ConnectionProfile(name: "Nowy", proto: .sftp, host: "h", username: "u")])   // nadpisuje główny klucz
        XCTAssertEqual(defaults.data(forKey: store.backupKey), garbage, "stare dane przeżywają nadpisanie")
        XCTAssertEqual(store.load().count, 1)
    }

    func testSettingsStoreKeepsUnreadableData() {
        let defaults = UserDefaults(suiteName: "oc-bk-\(UUID().uuidString)")!
        let garbage = Data("nie-json".utf8)
        defaults.set(garbage, forKey: "s")
        let store = SettingsStore(defaults: defaults, key: "s")
        XCTAssertEqual(store.load(), AppSettings.defaults)
        XCTAssertEqual(defaults.data(forKey: store.backupKey), garbage)
    }

    func testTrustedHostsStoreKeepsCorruptedFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oc-th-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TrustedHostsStore(url: dir.appendingPathComponent("hosts.json"))
        let garbage = Data("{uszkodzone".utf8)
        try garbage.write(to: dir.appendingPathComponent("hosts.json"))

        XCTAssertTrue(store.load().entries.isEmpty)
        XCTAssertEqual(try Data(contentsOf: store.backupURL), garbage)
    }
}

// MARK: - Klucz hosta zmieniony w trakcie pytania

final class HostKeyRaceTests: XCTestCase {
    func testKeySavedByAnotherConnectionDuringPromptBlocksTheConnection() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oc-hk-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TrustedHostsStore(url: dir.appendingPathComponent("hosts.json"))
        let mine = HostKeyInfo(host: "h", port: 22, keyType: "ssh-ed25519", fingerprint: "SHA256:moj")
        let other = HostKeyInfo(host: "h", port: 22, keyType: "ssh-ed25519", fingerprint: "SHA256:inny")

        let verifier = HostKeyVerifier(store: store) { _ in
            // W trakcie pytania inne połączenie zapisuje inny klucz tego samego hosta.
            var h = store.load(); h.trust(other); try? store.save(h)
            return true
        }
        do {
            try await verifier.verify(mine)
            XCTFail("połączenie z niezgodnym kluczem nie może przejść")
        } catch let e as NetworkError {
            guard case .hostKeyChanged = e else { return XCTFail("oczekiwano hostKeyChanged, jest \(e)") }
        }
        XCTAssertEqual(store.load().entries.map(\.fingerprint), ["SHA256:inny"], "cudzy wpis nie jest nadpisany")
    }
}

// MARK: - Walidacja profilu

final class ProfileValidationTests: XCTestCase {
    func testWebDAVAddressIsTrimmed() {
        let p = ConnectionProfile(name: "x", proto: .webdav, username: "u", baseURL: "  https://dav.example.test/x/ \n")
        XCTAssertEqual(p.webDAVURL?.host, "dav.example.test")
        XCTAssertNil(p.validationError())
    }

    func testWebDAVPasswordLoginRequiresUsername() {
        let p = ConnectionProfile(name: "x", proto: .webdav, username: "", baseURL: "https://dav.example.test/", auth: .password)
        XCTAssertNotNil(p.validationError(), "bez użytkownika żądania szłyby bez logowania")
        var anon = p; anon.auth = .anonymous
        XCTAssertNil(anon.validationError())
    }
}
