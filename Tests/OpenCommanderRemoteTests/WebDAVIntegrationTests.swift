import XCTest
@testable import OpenCommanderRemote
@testable import OpenCommanderCore

/// Hermetyczne testy WebDAV na prawdziwym HTTP: serwer w procesie testowym (127.0.0.1) i katalog tymczasowy.
final class WebDAVIntegrationTests: XCTestCase {
    var base: URL!, root: URL!, work: URL!
    var server: TestDAVServer!

    override func setUp() async throws {
        base = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().appendingPathComponent("oc-dav-\(UUID().uuidString)")
        root = base.appendingPathComponent("srv"); work = base.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        server?.stop()
        try? FileManager.default.removeItem(at: base)
    }

    // MARK: Narzędzia

    func start(prefix: String = "") async throws {
        server = try await TestDAVServer.start(root: root, prefix: prefix)
    }

    func profile(url: String? = nil, auth: AuthMode = .password) -> ConnectionProfile {
        ConnectionProfile(name: "dav", proto: .webdav, username: server.username, baseURL: url ?? server.baseURL, auth: auth, allowInsecure: true, connectTimeoutSeconds: 10)
    }

    func provider(password: String? = nil, url: String? = nil, auth: AuthMode = .password, connect: Bool = true) async throws -> WebDAVProvider {
        let ctx = ProviderContext(credentials: ConnectionCredentials(password: password ?? server.password),
                                  hostKeyVerifier: HostKeyVerifier(store: TrustedHostsStore(url: base.appendingPathComponent("h.json"))) { _ in false })
        let p = try WebDAVProvider(profile: profile(url: url, auth: auth), context: ctx)
        if connect { try await p.connect() }
        return p
    }

    func write(_ name: String, _ text: String, in dir: URL? = nil) throws {
        try text.write(to: (dir ?? root).appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func localFile(_ name: String, bytes: Int) throws -> URL {
        let u = work.appendingPathComponent(name)
        var d = Data(count: bytes); for i in 0..<bytes { d[i] = UInt8(truncatingIfNeeded: i &* 31 &+ 7) }
        try d.write(to: u); return u
    }

    func engine(_ p: any FileProvider) -> FileOperationEngine {
        FileOperationEngine(remote: RemoteTransferEngine(providerFor: { _ in p }))
    }

    // MARK: Połączenie i listowanie

    func testConnectAndListWithUnicodeAndSpecialCharacters() async throws {
        try await start()
        try write("raport #1 (100%) ?&.txt", "treść")
        try write("zażółć gęślą.txt", "x")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Mój folder"), withIntermediateDirectories: true)
        let p = try await provider(); defer { Task { await p.disconnect() } }
        let list = try await p.list(.root)
        XCTAssertEqual(Set(list.map(\.name)), ["raport #1 (100%) ?&.txt", "zażółć gęślą.txt", "Mój folder"])
        XCTAssertEqual(list.first { $0.name == "Mój folder" }?.kind, .directory)
        XCTAssertEqual(list.first { $0.name == "zażółć gęślą.txt" }?.size, 1)
        XCTAssertNotNil(list.first { $0.name == "zażółć gęślą.txt" }?.modified)
        let sub = try await p.list(RemotePath(parsing: "/Mój folder"))
        XCTAssertTrue(sub.isEmpty, "listing pustego folderu pomija sam folder")
    }

    func testWorksUnderPathPrefix() async throws {
        let prefix = "/remote.php/dav/files/ola"
        try await start(prefix: prefix)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Dokumenty"), withIntermediateDirectories: true)
        try write("a.txt", "A", in: root.appendingPathComponent("Dokumenty"))
        let p = try await provider(); defer { Task { await p.disconnect() } }
        let top = try await p.list(.root).map(\.name)
        let inner = try await p.list(RemotePath(parsing: "/Dokumenty")).map(\.name)
        XCTAssertEqual(top, ["Dokumenty"])
        XCTAssertEqual(inner, ["a.txt"])
        let up = try localFile("nowy.bin", bytes: 1000)
        try await p.upload(from: up, to: RemotePath(parsing: "/Dokumenty/nowy.bin"), overwrite: false) { _ in }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Dokumenty/nowy.bin").path))
        XCTAssertTrue(server.requests.allSatisfy { $0.path.hasPrefix(prefix) }, "wszystkie żądania idą pod prefiksem")
    }

    func testStatReturnsFileDirectoryAndNil() async throws {
        try await start()
        try write("plik.txt", "12345")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("katalog"), withIntermediateDirectories: true)
        let p = try await provider(); defer { Task { await p.disconnect() } }
        let f = try await p.stat(RemotePath(parsing: "/plik.txt"))
        XCTAssertEqual(f?.kind, .file); XCTAssertEqual(f?.size, 5)
        let d = try await p.stat(RemotePath(parsing: "/katalog"))
        let missing = try await p.stat(RemotePath(parsing: "/nie-ma"))
        XCTAssertEqual(d?.kind, .directory)
        XCTAssertNil(missing)
    }

    // MARK: Uwierzytelnianie

    func testWrongPasswordIsAuthenticationFailureWithoutLeakingSecret() async throws {
        try await start()
        do { _ = try await provider(password: "złe-hasło-987"); XCTFail() }
        catch let e as NetworkError {
            XCTAssertEqual(e, .authenticationFailed)
            XCTAssertFalse(e.localizedDescription.contains("złe-hasło-987"))
        }
    }

    func testAnonymousAgainstProtectedServerFails() async throws {
        try await start()
        let ctx = ProviderContext(credentials: ConnectionCredentials(), hostKeyVerifier: HostKeyVerifier(store: TrustedHostsStore(url: base.appendingPathComponent("h.json"))) { _ in false })
        let p = try WebDAVProvider(profile: profile(auth: .anonymous), context: ctx)
        do { try await p.connect(); XCTFail() } catch { XCTAssertEqual(error as? NetworkError, .authenticationFailed) }
    }

    func testCredentialsAppearOnlyAfterServerChallenge() async throws {
        try await start()
        let p = try await provider(); defer { Task { await p.disconnect() } }
        _ = try await p.list(.root)
        let first = try XCTUnwrap(server.requests.first)
        XCTAssertNil(first.headers["authorization"], "pierwsze żądanie idzie bez Authorization — poświadczenia dopiero po wyzwaniu serwera")
        XCTAssertNotNil(server.requests.last?.headers["authorization"], "kolejne żądania do tego samego serwera niosą Basic (bez podwójnego wysyłania treści)")
    }

    // MARK: Transfery i zmiany

    func testUploadDownloadRoundTripWithProgress() async throws {
        try await start()
        let p = try await provider(); defer { Task { await p.disconnect() } }
        let src = try localFile("duży.bin", bytes: 1_500_000)
        let sent = ProgressBox()
        try await p.upload(from: src, to: RemotePath(parsing: "/duży.bin"), overwrite: false) { sent.last = $0 }
        XCTAssertEqual(sent.last, 1_500_000)
        let dst = work.appendingPathComponent("pobrany.bin")
        let got = ProgressBox()
        try await p.download(RemotePath(parsing: "/duży.bin"), to: dst) { got.last = $0 }
        XCTAssertEqual(try Data(contentsOf: dst), try Data(contentsOf: src))
        XCTAssertEqual(got.last, 1_500_000)
    }

    func testUploadNeverOverwritesWithoutExplicitOverwrite() async throws {
        try await start()
        try write("jest.txt", "stare")
        let p = try await provider(); defer { Task { await p.disconnect() } }
        let src = work.appendingPathComponent("n.txt"); try "nowe".write(to: src, atomically: true, encoding: .utf8)
        do { try await p.upload(from: src, to: RemotePath(parsing: "/jest.txt"), overwrite: false) { _ in }; XCTFail() }
        catch let e as NetworkError { if case .conflict = e {} else { XCTFail("\(e)") } }
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("jest.txt")), "stare")
        try await p.upload(from: src, to: RemotePath(parsing: "/jest.txt"), overwrite: true) { _ in }
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("jest.txt")), "nowe")
    }

    func testTruncatedDownloadIsAnErrorNotASuccess() async throws {
        try await start()
        try write("plik.bin", String(repeating: "x", count: 100_000))
        server.truncateGet = true
        let p = try await provider(); defer { Task { await p.disconnect() } }
        do { try await p.download(RemotePath(parsing: "/plik.bin"), to: work.appendingPathComponent("o.bin")) { _ in }; XCTFail("niekompletne pobranie") }
        catch { XCTAssertTrue([NetworkError.connectionLost, .timeout].contains(error as? NetworkError ?? .cancelled) || error is NetworkError, "\(error)") }
    }

    func testMakeDirectoryRenameAndDelete() async throws {
        try await start()
        let p = try await provider(); defer { Task { await p.disconnect() } }
        try await p.makeDirectory(RemotePath(parsing: "/Nowy folder"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Nowy folder").path))
        do { try await p.makeDirectory(RemotePath(parsing: "/Nowy folder")); XCTFail() } catch let e as NetworkError { if case .conflict = e {} else { XCTFail("\(e)") } }
        do { try await p.makeDirectory(RemotePath(parsing: "/brak/pod")); XCTFail() } catch let e as NetworkError { if case .notFound = e {} else { XCTFail("\(e)") } }

        try write("a.txt", "A")
        try await p.rename(RemotePath(parsing: "/a.txt"), to: RemotePath(parsing: "/b ą.txt"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("a.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("b ą.txt").path))
        try write("c.txt", "C")
        do { try await p.rename(RemotePath(parsing: "/c.txt"), to: RemotePath(parsing: "/b ą.txt")); XCTFail("nie nadpisuje") } catch let e as NetworkError { if case .conflict = e {} else { XCTFail("\(e)") } }
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("b ą.txt")), "A")

        try await p.rename(RemotePath(parsing: "/Nowy folder"), to: RemotePath(parsing: "/Zmieniony"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Zmieniony").path))

        try await p.delete(RemotePath(parsing: "/c.txt"), isDirectory: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("c.txt").path))
        try await p.delete(RemotePath(parsing: "/Zmieniony"), isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Zmieniony").path))
    }

    func testDeleteRefusesNonEmptyDirectoryBecauseDAVDeleteIsRecursive() async throws {
        try await start()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("pełny"), withIntermediateDirectories: true)
        try write("w.txt", "w", in: root.appendingPathComponent("pełny"))
        let p = try await provider(); defer { Task { await p.disconnect() } }
        do { try await p.delete(RemotePath(parsing: "/pełny"), isDirectory: true); XCTFail() } catch let e as NetworkError { if case .conflict = e {} else { XCTFail("\(e)") } }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("pełny/w.txt").path), "zawartość nietknięta")
    }

    // MARK: Błędy HTTP i przekierowania

    func testHttpStatusMapping() async throws {
        try await start()
        let p = try await provider(); defer { Task { await p.disconnect() } }
        func fails(_ status: Int, expecting check: (NetworkError) -> Bool, _ line: UInt = #line) async {
            server.canned["PROPFIND /x/"] = .init(status: status)
            do { _ = try await p.list(RemotePath(parsing: "/x")); XCTFail("status \(status)", line: line) }
            catch { XCTAssertTrue(check(error as? NetworkError ?? .cancelled), "status \(status): \(error)", line: line) }
        }
        await fails(403) { if case .permissionDenied = $0 { return true }; return false }
        await fails(404) { if case .notFound = $0 { return true }; return false }
        await fails(401) { $0 == .authenticationFailed }
        await fails(507) { $0 == .noSpace }
        await fails(503) { if case .connectionFailed = $0 { return true }; return false }
        await fails(405) { if case .unsupported = $0 { return true }; return false }
    }

    func testSameHostRedirectIsFollowedForCollectionWithoutSlash() async throws {
        try await start()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("dok"), withIntermediateDirectories: true)
        try write("w.txt", "w", in: root.appendingPathComponent("dok"))
        server.canned["PROPFIND /dok"] = .init(status: 301, headers: ["Location": "/dok/"])
        let p = try await provider(); defer { Task { await p.disconnect() } }
        let e = try await p.stat(RemotePath(parsing: "/dok"))
        XCTAssertEqual(e?.kind, .directory)
    }

    func testRedirectToAnotherServerIsRefusedAndNoCredentialsAreSentThere() async throws {
        try await start()
        let otherRoot = base.appendingPathComponent("other"); try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        let other = try await TestDAVServer.start(root: otherRoot); defer { other.stop() }
        server.canned["PROPFIND /przekieruj/"] = .init(status: 302, headers: ["Location": "http://127.0.0.1:\(other.port)/"])
        let p = try await provider(); defer { Task { await p.disconnect() } }
        do { _ = try await p.list(RemotePath(parsing: "/przekieruj")); XCTFail() }
        catch let e as NetworkError { if case .insecureConnectionRefused = e {} else { XCTFail("\(e)") } }
        XCTAssertTrue(other.requests.isEmpty, "obcy serwer nie dostał żadnego żądania (ani poświadczeń)")
    }

    func testRedirectLoopIsBounded() async throws {
        try await start()
        server.canned["PROPFIND /petla/"] = .init(status: 302, headers: ["Location": "/petla/"])
        let p = try await provider(); defer { Task { await p.disconnect() } }
        do { _ = try await p.list(RemotePath(parsing: "/petla")); XCTFail() } catch { XCTAssertTrue(error is NetworkError) }
    }

    func testBrokenXMLFromServerIsReadableError() async throws {
        try await start()
        server.canned["PROPFIND /zly/"] = .init(status: 207, headers: ["Content-Type": "application/xml"], body: "<D:multistatus")
        let p = try await provider(); defer { Task { await p.disconnect() } }
        do { _ = try await p.list(RemotePath(parsing: "/zly")); XCTFail() } catch let e as NetworkError { if case .invalidResponse = e {} else { XCTFail("\(e)") } }
    }

    func testUnreachableServerAndSessionLoss() async throws {
        try await start()
        let p = try await provider()
        server.stop()
        try await Task.sleep(nanoseconds: 200_000_000)
        do { _ = try await p.list(.root); XCTFail() } catch let e as NetworkError {
            switch e { case .connectionFailed, .connectionLost, .timeout: break; default: XCTFail("\(e)") }
        }
        await p.disconnect()
        do { _ = try await p.list(.root); XCTFail() } catch { XCTAssertEqual(error as? NetworkError, .connectionLost) }
    }

    // MARK: Kolejka (silnik) na WebDAV

    func testEngineUploadsFolderTreeAndDownloadsBack() async throws {
        try await start()
        let src = work.appendingPathComponent("drzewo")
        try FileManager.default.createDirectory(at: src.appendingPathComponent("pod"), withIntermediateDirectories: true)
        try "a".write(to: src.appendingPathComponent("a ą.txt"), atomically: true, encoding: .utf8)
        try "b".write(to: src.appendingPathComponent("pod/b.txt"), atomically: true, encoding: .utf8)
        let p = try await provider(); defer { Task { await p.disconnect() } }
        let dest = RemoteLocation(connectionID: UUID(), path: .root).url
        let up = await engine(p).run(FileOperation(kind: .copy, sources: [src], destination: dest))
        XCTAssertTrue(up.failures.isEmpty, up.summary)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("drzewo/pod/b.txt")), "b")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("drzewo/a ą.txt")), "a")
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path), "źródło lokalne nietknięte")

        let back = base.appendingPathComponent("pobrane"); try FileManager.default.createDirectory(at: back, withIntermediateDirectories: true)
        let remoteDir = RemoteLocation(connectionID: UUID(), path: RemotePath(parsing: "/drzewo")).url
        let down = await engine(p).run(FileOperation(kind: .copy, sources: [remoteDir], destination: back))
        XCTAssertTrue(down.failures.isEmpty, down.summary)
        XCTAssertEqual(try String(contentsOf: back.appendingPathComponent("drzewo/pod/b.txt")), "b")
    }

    func testEngineRemoteDeleteRemovesTreeDepthFirst() async throws {
        try await start()
        let d = root.appendingPathComponent("do-usuniecia/pod"); try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try write("x.txt", "x", in: d); try write("y.txt", "y", in: root.appendingPathComponent("do-usuniecia"))
        let p = try await provider(); defer { Task { await p.disconnect() } }
        let url = RemoteLocation(connectionID: UUID(), path: RemotePath(parsing: "/do-usuniecia")).url
        let r = await engine(p).run(FileOperation(kind: .delete, sources: [url]))
        XCTAssertTrue(r.failures.isEmpty, r.summary)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("do-usuniecia").path))
    }

    func testDroppedUploadLeavesNoFinalFileAndNoTemp() async throws {
        try await start()
        server.dropPutAfterBytes = 100_000
        let big = try localFile("duży.bin", bytes: 3_000_000)
        let p = try await provider(); defer { Task { await p.disconnect() } }
        let dest = RemoteLocation(connectionID: UUID(), path: .root).url
        let r = await engine(p).run(FileOperation(kind: .copy, sources: [big], destination: dest))
        XCTAssertEqual(r.failures.count, 1, r.summary)
        server.dropPutAfterBytes = nil
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertFalse(names.contains("duży.bin"), "przerwany upload nie wygląda na kompletny plik: \(names)")
        XCTAssertTrue(names.allSatisfy { !$0.hasPrefix(".opencommander-tmp-") }, "własny plik tymczasowy posprzątany: \(names)")
        XCTAssertFalse((r.failures.first?.1.localizedDescription ?? "").contains(server.password))
    }

    func testCancelDuringUploadLeavesNothingOnServer() async throws {
        try await start()
        let big = try localFile("duży.bin", bytes: 3_000_000)
        let p = try await provider(); defer { Task { await p.disconnect() } }
        let box = TaskBox()
        let hooked = HookProvider(base: p) { sent in if sent > 100_000 { box.task?.cancel() } }
        let eng = engine(hooked)
        let dest = RemoteLocation(connectionID: UUID(), path: .root).url
        let task = Task { await eng.run(FileOperation(kind: .copy, sources: [big], destination: dest)) }
        box.task = task
        let r = await task.value
        XCTAssertEqual(r.cancelledCount, 1, r.summary)
        try await Task.sleep(nanoseconds: 300_000_000)
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertTrue(names.isEmpty, "po anulowaniu nic nie zostaje na serwerze: \(names)")
    }

    func testManagerEndToEndWithWebDAVFactoryAndNoSecretsInProfile() async throws {
        try await start()
        let defaults = UserDefaults(suiteName: "oc-dav-\(UUID().uuidString)")!
        let secrets = InMemorySecretStore()
        let m = await ConnectionManager(profileStore: ProfileStore(defaults: defaults, key: "p"), secrets: secrets,
                                        trustedHostsStore: TrustedHostsStore(url: base.appendingPathComponent("h.json")))
        await MainActor.run { RemoteModule.install(in: m) }
        let saved = try await MainActor.run { try m.save(profile(), password: server.password) }
        let raw = String(data: defaults.data(forKey: "p")!, encoding: .utf8)!
        XCTAssertFalse(raw.contains(server.password))
        try write("z.txt", "z")
        let loc = try await m.initialLocation(for: saved.id)
        let entries = try await m.listing(loc)
        XCTAssertEqual(entries.map(\.name), ["z.txt"])
        XCTAssertTrue(entries[0].url.isRemoteLocation)
        let test = await m.test(profile(), password: server.password, passphrase: nil)
        if case .failure(let e) = test { XCTFail("\(e)") }
        await m.disconnect(saved.id)
    }
}
