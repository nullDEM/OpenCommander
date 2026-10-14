import XCTest
@testable import OpenCommanderRemote
@testable import OpenCommanderCore

/// Hermetyczne testy FTP na prawdziwym libcurl: serwer w procesie testowym (127.0.0.1) i katalog tymczasowy.
final class FTPIntegrationTests: XCTestCase {
    var base: URL!, root: URL!, work: URL!
    var server: TestFTPServer!

    override func setUp() async throws {
        base = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().appendingPathComponent("oc-ftp-\(UUID().uuidString)")
        root = base.appendingPathComponent("srv"); work = base.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        server = try await TestFTPServer.start(root: root)
    }
    override func tearDown() async throws { server?.stop(); try? FileManager.default.removeItem(at: base) }

    // MARK: Narzędzia

    func profile(proto: ConnectionProtocol = .ftp, auth: AuthMode = .password, initialPath: String = "") -> ConnectionProfile {
        ConnectionProfile(name: "ftp", proto: proto, host: "127.0.0.1", port: server.port, username: server.username, initialPath: initialPath,
                          auth: auth, allowInsecure: proto == .ftp, connectTimeoutSeconds: 3)
    }
    func ctx(_ password: String? = nil) -> ProviderContext {
        ProviderContext(credentials: ConnectionCredentials(password: password ?? server.password),
                        hostKeyVerifier: HostKeyVerifier(store: TrustedHostsStore(url: base.appendingPathComponent("h.json"))) { _ in false })
    }
    func provider(password: String? = nil, initialPath: String = "", connect: Bool = true) async throws -> FTPProvider {
        let p = try FTPProvider(profile: profile(initialPath: initialPath), context: ctx(password))
        if connect { try await p.connect() }
        return p
    }
    func write(_ name: String, _ text: String, in dir: URL? = nil) throws { try text.write(to: (dir ?? root).appendingPathComponent(name), atomically: true, encoding: .utf8) }
    func localFile(_ name: String, bytes: Int) throws -> URL {
        let u = work.appendingPathComponent(name)
        var d = Data(count: bytes); for i in 0..<bytes { d[i] = UInt8(truncatingIfNeeded: i &* 31 &+ 7) }
        try d.write(to: u); return u
    }
    func engine(_ p: any FileProvider) -> FileOperationEngine { FileOperationEngine(remote: RemoteTransferEngine(providerFor: { _ in p })) }

    // MARK: Profil i bezpieczeństwo

    func testPlainFTPRequiresExplicitConsent() throws {
        var p = profile(); p.allowInsecure = false
        XCTAssertNotNil(p.validationError())
        XCTAssertThrowsError(try FTPProvider(profile: p, context: ctx()))
    }

    func testFTPSDoesNotSilentlyDowngradeWhenServerHasNoTLS() async throws {
        // serwer testowy odpowiada 502 na AUTH TLS — klient FTPS ma odmówić, a nie wysłać hasła jawnie
        let p = try FTPProvider(profile: profile(proto: .ftps), context: ctx())
        do { try await p.connect(); XCTFail("FTPS bez TLS po stronie serwera musi się nie udać") }
        catch let e as NetworkError { if case .insecureConnectionRefused = e {} else { XCTFail("\(e)") } }
        XCTAssertFalse(server.commands.contains("PASS"), "hasło nie może zostać wysłane bez TLS")
        XCTAssertFalse(server.commands.contains { $0.hasPrefix("USER") }, "nawet nazwa użytkownika nie idzie jawnie")
    }

    // MARK: Połączenie, listowanie

    func testConnectUsesHomeFromPWDAndListsWithMLSD() async throws {
        server.homeDir = "/Dokumenty"
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Dokumenty"), withIntermediateDirectories: true)
        try write("a ą.txt", "AAA", in: root.appendingPathComponent("Dokumenty"))
        let p = try await provider(); defer { Task { await p.disconnect() } }
        let home = try await p.initialPath()
        XCTAssertEqual(home.string, "/Dokumenty")
        let list = try await p.list(home)
        XCTAssertEqual(list.map(\.name), ["a ą.txt"]); XCTAssertEqual(list[0].size, 3)
        XCTAssertTrue(server.commands.contains { $0.hasPrefix("MLSD") }, "preferowane MLSD")
        XCTAssertTrue(p.capabilities.reliableMetadata)
    }

    func testFallsBackToLISTWhenServerHasNoMLSDAndMarksMetadataAsHeuristic() async throws {
        server.supportsMLSD = false
        try write("plik.txt", "12345")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("katalog"), withIntermediateDirectories: true)
        let p = try await provider(); defer { Task { await p.disconnect() } }
        let list = try await p.list(.root)
        XCTAssertEqual(Set(list.map(\.name)), ["plik.txt", "katalog"])
        XCTAssertEqual(list.first { $0.name == "plik.txt" }?.size, 5)
        XCTAssertEqual(list.first { $0.name == "katalog" }?.kind, .directory)
        XCTAssertFalse(p.capabilities.reliableMetadata, "po przejściu na LIST metadane są heurystyczne")
    }

    func testPassiveModeIgnoresForeignIPFromPASVReply() async throws {
        server.brokenPassiveIP = true
        try write("x.txt", "x")
        let p = try await provider(); defer { Task { await p.disconnect() } }
        // EPSV jest preferowany, ale nawet gdyby serwer wymusił PASV z obcym IP, klient łączy się pod adres sterujący.
        let list = try await p.list(.root)
        XCTAssertEqual(list.map(\.name), ["x.txt"])
    }

    func testWrongPasswordAndAnonymousAgainstProtectedServer() async throws {
        do { _ = try await provider(password: "złe-hasło-987"); XCTFail() }
        catch let e as NetworkError { XCTAssertEqual(e, .authenticationFailed); XCTAssertFalse(e.localizedDescription.contains("złe-hasło-987")) }
        let anon = try FTPProvider(profile: profile(auth: .anonymous), context: ctx())
        do { try await anon.connect(); XCTFail() } catch { XCTAssertEqual(error as? NetworkError, .authenticationFailed) }
    }

    func testConnectionRefusedAndSessionLoss() async throws {
        let p = try await provider()
        server.stop(); try await Task.sleep(nanoseconds: 300_000_000)
        do { _ = try await p.list(.root); XCTFail() } catch let e as NetworkError {
            switch e { case .connectionFailed, .connectionLost, .timeout: break; default: XCTFail("\(e)") }
        }
        await p.disconnect()
        do { _ = try await p.list(.root); XCTFail() } catch { XCTAssertEqual(error as? NetworkError, .connectionLost) }
    }

    // MARK: Transfery i zmiany

    func testUploadDownloadRoundTripBinaryWithProgress() async throws {
        let p = try await provider(); defer { Task { await p.disconnect() } }
        let src = try localFile("duży.bin", bytes: 1_500_000)
        let sent = ProgressBox()
        try await p.upload(from: src, to: RemotePath(parsing: "/duży ą.bin"), overwrite: false) { sent.last = $0 }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("duży ą.bin")), try Data(contentsOf: src), "transfer binarny bez zmian bajtów")
        XCTAssertEqual(sent.last, 1_500_000)
        let dst = work.appendingPathComponent("pobrany.bin"); let got = ProgressBox()
        try await p.download(RemotePath(parsing: "/duży ą.bin"), to: dst) { got.last = $0 }
        XCTAssertEqual(try Data(contentsOf: dst), try Data(contentsOf: src))
        XCTAssertEqual(got.last, 1_500_000)
    }

    func testUploadRefusesToOverwriteWithoutExplicitFlag() async throws {
        try write("jest.txt", "stare")
        let p = try await provider(); defer { Task { await p.disconnect() } }
        let src = work.appendingPathComponent("n.txt"); try "nowe".write(to: src, atomically: true, encoding: .utf8)
        do { try await p.upload(from: src, to: RemotePath(parsing: "/jest.txt"), overwrite: false) { _ in }; XCTFail() }
        catch let e as NetworkError { if case .conflict = e {} else { XCTFail("\(e)") } }
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("jest.txt")), "stare")
        try await p.upload(from: src, to: RemotePath(parsing: "/jest.txt"), overwrite: true) { _ in }
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("jest.txt")), "nowe")
    }

    func testTruncatedDownloadIsAnError() async throws {
        try write("p.bin", String(repeating: "x", count: 300_000))
        server.truncateRetr = true
        let p = try await provider(); defer { Task { await p.disconnect() } }
        do { try await p.download(RemotePath(parsing: "/p.bin"), to: work.appendingPathComponent("o.bin")) { _ in }; XCTFail("niekompletne pobranie") }
        catch { XCTAssertTrue(error is NetworkError, "\(error)") }
    }

    func testMakeDirectoryRenameDeleteWithReadableErrors() async throws {
        let p = try await provider(); defer { Task { await p.disconnect() } }
        try await p.makeDirectory(RemotePath(parsing: "/Nowy folder"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Nowy folder").path))
        do { try await p.makeDirectory(RemotePath(parsing: "/Nowy folder")); XCTFail() } catch let e as NetworkError { if case .conflict = e {} else { XCTFail("\(e)") } }
        do { try await p.makeDirectory(RemotePath(parsing: "/brak/pod")); XCTFail() } catch let e as NetworkError { if case .notFound = e {} else { XCTFail("\(e)") } }
        try write("a.txt", "A")
        try await p.rename(RemotePath(parsing: "/a.txt"), to: RemotePath(parsing: "/b ą.txt"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("b ą.txt").path))
        try write("c.txt", "C")
        do { try await p.rename(RemotePath(parsing: "/c.txt"), to: RemotePath(parsing: "/b ą.txt")); XCTFail() } catch let e as NetworkError { if case .conflict = e {} else { XCTFail("\(e)") } }
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("b ą.txt")), "A")
        try await p.delete(RemotePath(parsing: "/c.txt"), isDirectory: false)
        try await p.delete(RemotePath(parsing: "/Nowy folder"), isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Nowy folder").path))
        do { try await p.delete(RemotePath(parsing: "/nie-ma"), isDirectory: false); XCTFail() } catch let e as NetworkError { if case .notFound = e {} else { XCTFail("\(e)") } }
    }

    func testDeleteRefusesNonEmptyDirectory() async throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("pełny"), withIntermediateDirectories: true)
        try write("w.txt", "w", in: root.appendingPathComponent("pełny"))
        let p = try await provider(); defer { Task { await p.disconnect() } }
        do { try await p.delete(RemotePath(parsing: "/pełny"), isDirectory: true); XCTFail() } catch let e as NetworkError { if case .conflict = e {} else { XCTFail("\(e)") } }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("pełny/w.txt").path))
    }

    func testCommandInjectionThroughNamesIsBlocked() async throws {
        let p = try await provider(); defer { Task { await p.disconnect() } }
        do { try await p.makeDirectory(RemotePath(parsing: "/ok\r\nDELE x")); XCTFail("CR/LF w nazwie") } catch { XCTAssertTrue(error is NetworkError) }
        XCTAssertFalse(server.commands.contains { $0.hasPrefix("DELE") }, "do serwera nie dotarło wstrzyknięte polecenie")
    }

    // MARK: Silnik kolejki

    func testEngineUploadsTreeAndDownloadsBackAndRemoteDelete() async throws {
        let src = work.appendingPathComponent("drzewo")
        try FileManager.default.createDirectory(at: src.appendingPathComponent("pod"), withIntermediateDirectories: true)
        try "a".write(to: src.appendingPathComponent("a ą.txt"), atomically: true, encoding: .utf8)
        try "b".write(to: src.appendingPathComponent("pod/b.txt"), atomically: true, encoding: .utf8)
        let p = try await provider(); defer { Task { await p.disconnect() } }
        let dest = RemoteLocation(connectionID: UUID(), path: .root).url
        let up = await engine(p).run(FileOperation(kind: .copy, sources: [src], destination: dest))
        XCTAssertTrue(up.failures.isEmpty, up.summary)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("drzewo/pod/b.txt")), "b")
        let back = base.appendingPathComponent("pobrane"); try FileManager.default.createDirectory(at: back, withIntermediateDirectories: true)
        let remoteDir = RemoteLocation(connectionID: UUID(), path: RemotePath(parsing: "/drzewo")).url
        let down = await engine(p).run(FileOperation(kind: .copy, sources: [remoteDir], destination: back))
        XCTAssertTrue(down.failures.isEmpty, down.summary)
        XCTAssertEqual(try String(contentsOf: back.appendingPathComponent("drzewo/a ą.txt")), "a")
        let del = await engine(p).run(FileOperation(kind: .delete, sources: [remoteDir]))
        XCTAssertTrue(del.failures.isEmpty, del.summary)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("drzewo").path))
    }

    func testDroppedUploadLeavesNoFinalFile() async throws {
        server.dropStorAfterBytes = 100_000
        let big = try localFile("duży.bin", bytes: 3_000_000)
        let p = try await provider(); defer { Task { await p.disconnect() } }
        let dest = RemoteLocation(connectionID: UUID(), path: .root).url
        let r = await engine(p).run(FileOperation(kind: .copy, sources: [big], destination: dest))
        XCTAssertEqual(r.failures.count, 1, r.summary)
        server.dropStorAfterBytes = nil
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertFalse(names.contains("duży.bin"), "przerwany upload nie wygląda jak kompletny plik: \(names)")
        XCTAssertFalse((r.failures.first?.1.localizedDescription ?? "").contains(server.password))
    }

    func testCancelDuringUploadAbortsTransfer() async throws {
        let big = try localFile("duży.bin", bytes: 20_000_000)
        let p = try await provider(); defer { Task { await p.disconnect() } }
        let box = TaskBox()
        let hooked = HookProvider(base: p) { sent in if sent > 200_000 { box.task?.cancel() } }
        let eng = engine(hooked)
        let dest = RemoteLocation(connectionID: UUID(), path: .root).url
        let task = Task { await eng.run(FileOperation(kind: .copy, sources: [big], destination: dest)) }
        box.task = task
        let r = await task.value
        XCTAssertEqual(r.cancelledCount, 1, r.summary)
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertFalse(names.contains("duży.bin"))
    }
}
