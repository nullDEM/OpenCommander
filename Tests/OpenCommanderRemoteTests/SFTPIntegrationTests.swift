import XCTest
import Crypto
@testable import OpenCommanderRemote
@testable import OpenCommanderCore

/// Hermetyczne testy integracyjne SFTP: serwer Citadel w procesie testowym na 127.0.0.1, katalog tymczasowy, bez sieci zewnętrznej.
final class SFTPIntegrationTests: XCTestCase {
    var root: URL!          // katalog serwera
    var work: URL!          // katalog roboczy klienta
    var server: TestSFTPServer!
    var hostsURL: URL!
    var asked: [HostKeyInfo] = []

    override func setUp() async throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().appendingPathComponent("oc-sftp-\(UUID().uuidString)")
        root = base.appendingPathComponent("srv"); work = base.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        hostsURL = base.appendingPathComponent("hosts.json")
        asked = []
        server = try await TestSFTPServer.start(root: root)
    }

    override func tearDown() async throws {
        await server?.stop()
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    // MARK: Narzędzia

    func profile(port: Int? = nil) -> ConnectionProfile {
        ConnectionProfile(name: "test", proto: .sftp, host: "127.0.0.1", port: port ?? server.port, username: server.username, initialPath: "")
    }

    func verifier(accept: Bool = true) -> HostKeyVerifier {
        HostKeyVerifier(store: TrustedHostsStore(url: hostsURL)) { [unowned self] info in self.asked.append(info); return accept }
    }

    func connected(password: String? = nil, accept: Bool = true) async throws -> SFTPProvider {
        let p = SFTPProvider(profile: profile(), context: ProviderContext(
            credentials: ConnectionCredentials(password: password ?? server.password), hostKeyVerifier: verifier(accept: accept)))
        try await p.connect()
        return p
    }

    func writeLocal(_ name: String, bytes: Int, in dir: URL? = nil) throws -> URL {
        let u = (dir ?? work).appendingPathComponent(name)
        var data = Data(count: bytes)
        for i in stride(from: 0, to: bytes, by: 1) { data[i] = UInt8(truncatingIfNeeded: i &* 31 &+ 7) }
        try data.write(to: u); return u
    }

    /// Ręczne testy interfejsu: uruchamia serwer na 127.0.0.1:2222 (katalog tymczasowy z plikami demo) na `OC_SERVE_SECONDS` s.
    /// Pomijany w zwykłym przebiegu. Hasło testowe: `TestSFTPServer.defaultPassword`; użytkownik: „ola”.
    func testServeForManualUI() async throws {
        guard let secs = ProcessInfo.processInfo.environment["OC_SERVE_SECONDS"].flatMap(Double.init) else { throw XCTSkip("tylko na żądanie") }
        let demo = root.deletingLastPathComponent().appendingPathComponent("demo")
        try FileManager.default.createDirectory(at: demo.appendingPathComponent("Projekty"), withIntermediateDirectories: true)
        try "treść".write(to: demo.appendingPathComponent("raport #1 (100%).txt"), atomically: true, encoding: .utf8)
        try "x".write(to: demo.appendingPathComponent("zażółć gęślą.txt"), atomically: true, encoding: .utf8)
        try "w środku".write(to: demo.appendingPathComponent("Projekty/notatka.txt"), atomically: true, encoding: .utf8)
        let srv = try await TestSFTPServer.start(root: demo, port: 2222)
        defer { Task { await srv.stop() } }
        FileManager.default.createFile(atPath: root.deletingLastPathComponent().appendingPathComponent("READY").path, contents: nil)
        try await Task.sleep(nanoseconds: UInt64(secs * 1_000_000_000))
    }

    // MARK: Połączenie i zaufanie do klucza

    func testConnectPromptsForUnknownHostKeyShowsFingerprintAndPersistsTrust() async throws {
        let p = try await connected()
        await p.disconnect()
        XCTAssertEqual(asked.count, 1)
        XCTAssertEqual(asked[0].keyType, "ssh-ed25519")
        XCTAssertEqual(asked[0].fingerprint, server.hostKeyInfo.fingerprint, "odcisk pokazywany użytkownikowi = odcisk klucza serwera")
        XCTAssertTrue(asked[0].fingerprint.hasPrefix("SHA256:"))
        let p2 = try await connected(); await p2.disconnect()
        XCTAssertEqual(asked.count, 1, "po akceptacji nie pytamy ponownie")
    }

    func testRejectedHostKeyBlocksConnectionAndSavesNothing() async throws {
        do { _ = try await connected(accept: false); XCTFail() } catch { XCTAssertEqual(error as? NetworkError, .hostKeyRejected) }
        XCTAssertEqual(TrustedHostsStore(url: hostsURL).load().entries.count, 0)
    }

    func testChangedHostKeyBlocksWithoutPromptAndLeavesTrustUntouched() async throws {
        var t = TrustedHosts()
        t.trust(HostKeyInfo(host: "127.0.0.1", port: server.port, keyType: "ssh-ed25519", fingerprint: "SHA256:ZAUFANY-INNY-KLUCZ"))
        try TrustedHostsStore(url: hostsURL).save(t)
        do { _ = try await connected(); XCTFail("zmiana klucza musi blokować") }
        catch NetworkError.hostKeyChanged(let expected, let actual) {
            XCTAssertEqual(expected, "SHA256:ZAUFANY-INNY-KLUCZ"); XCTAssertEqual(actual.fingerprint, server.hostKeyInfo.fingerprint)
        }
        XCTAssertTrue(asked.isEmpty, "nowego klucza nie proponujemy do akceptacji")
        XCTAssertEqual(TrustedHostsStore(url: hostsURL).load().entries.first?.fingerprint, "SHA256:ZAUFANY-INNY-KLUCZ")
    }

    func testWrongPasswordIsAuthenticationFailedAndDoesNotLeakPassword() async throws {
        do { _ = try await connected(password: "ZleHaslo-999"); XCTFail() }
        catch let e as NetworkError {
            XCTAssertEqual(e, .authenticationFailed)
            XCTAssertFalse((e.errorDescription ?? "").contains("ZleHaslo-999"))
        }
    }

    func testConnectionRefusedIsReportedClearly() async throws {
        let dead = try TestSFTPServer.freePort()
        let p = SFTPProvider(profile: profile(port: dead), context: ProviderContext(credentials: .init(password: "x"), hostKeyVerifier: verifier()))
        do { try await p.connect(); XCTFail() } catch let e as NetworkError {
            switch e { case .connectionFailed, .timeout, .connectionLost: break; default: XCTFail("nieoczekiwany błąd: \(e)") }
        }
    }

    // MARK: Operacje

    func testInitialPathListMkdirUploadDownloadRoundTripWithMultiChunkFile() async throws {
        let p = try await connected(); defer { Task { await p.disconnect() } }
        let home = try await p.initialPath()
        XCTAssertEqual(home.string, "/")
        try await p.makeDirectory(RemotePath(parsing: "/dane"))
        let src = try writeLocal("duży.bin", bytes: 3 * SFTPProvider.chunkSize + 123)
        let progress = ProgressBox()
        try await p.upload(from: src, to: RemotePath(parsing: "/dane/duży.bin"), overwrite: false) { progress.last = $0 }
        XCTAssertEqual(progress.last, Int64(3 * SFTPProvider.chunkSize + 123))
        let entries = try await p.list(RemotePath(parsing: "/dane"))
        XCTAssertEqual(entries.map(\.name), ["duży.bin"]); XCTAssertEqual(entries[0].size, Int64(3 * SFTPProvider.chunkSize + 123))
        XCTAssertEqual(entries[0].kind, .file)
        let back = work.appendingPathComponent("z-serwera.bin")
        try await p.download(RemotePath(parsing: "/dane/duży.bin"), to: back) { _ in }
        XCTAssertEqual(try Data(contentsOf: back), try Data(contentsOf: src), "dane po round-trip identyczne")
    }

    func testRenameDeleteAndDirectoryRules() async throws {
        let p = try await connected(); defer { Task { await p.disconnect() } }
        let f = try writeLocal("a.txt", bytes: 10)
        try await p.makeDirectory(RemotePath(parsing: "/d"))
        try await p.upload(from: f, to: RemotePath(parsing: "/d/a.txt"), overwrite: false) { _ in }
        try await p.rename(RemotePath(parsing: "/d/a.txt"), to: RemotePath(parsing: "/d/b.txt"))
        let names = try await p.list(RemotePath(parsing: "/d")).map(\.name)
        XCTAssertEqual(names, ["b.txt"])
        // rename nie może nadpisać istniejącego
        try await p.upload(from: f, to: RemotePath(parsing: "/d/c.txt"), overwrite: false) { _ in }
        do { try await p.rename(RemotePath(parsing: "/d/b.txt"), to: RemotePath(parsing: "/d/c.txt")); XCTFail() } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("d/b.txt").path))
        // niepusty katalog nie jest usuwany; pusty tak
        do { try await p.delete(RemotePath(parsing: "/d"), isDirectory: true); XCTFail("niepusty katalog") } catch {}
        try await p.delete(RemotePath(parsing: "/d/b.txt"), isDirectory: false)
        try await p.delete(RemotePath(parsing: "/d/c.txt"), isDirectory: false)
        try await p.delete(RemotePath(parsing: "/d"), isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("d").path))
    }

    func testUnicodeAndSpecialCharacterNamesSurviveRoundTrip() async throws {
        let p = try await connected(); defer { Task { await p.disconnect() } }
        let names = ["zażółć gęślą jaźń.txt", "a#b?c&d=e%f.txt", "spacje  podwójne .txt", "日本語.txt", "emoji 😀.txt", "plus+nawias(1).txt"]
        for n in names {
            let src = try writeLocal(n, bytes: 50)
            try await p.upload(from: src, to: RemotePath.root.appending(n), overwrite: false) { _ in }
        }
        let listed = try await p.list(.root).map(\.name)
        for n in names { XCTAssertTrue(listed.contains(n), "brak „\(n)” na liście: \(listed)") }
        let back = work.appendingPathComponent("zwrot-\(UUID().uuidString)")
        try await p.download(try RemotePath.root.appending("a#b?c&d=e%f.txt"), to: back) { _ in }
        XCTAssertEqual(try Data(contentsOf: back).count, 50)
    }

    func testSymlinksAreListedAsSymlinksNotDirectories() async throws {
        let p = try await connected(); defer { Task { await p.disconnect() } }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("prawdziwy"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("lnk"), withDestinationURL: root.appendingPathComponent("prawdziwy"))
        let entries = try await p.list(.root)
        let link = try XCTUnwrap(entries.first { $0.name == "lnk" })
        XCTAssertEqual(link.kind, .symlink)
        XCTAssertEqual(link.symlinkTargetIsDirectory, true)
        let st = try await p.stat(RemotePath(parsing: "/lnk"))
        XCTAssertEqual(st?.kind, .symlink, "stat nie może pomylić dowiązania z katalogiem (inaczej usuwanie wchodziłoby do celu)")
        let missing = try await p.stat(RemotePath(parsing: "/nie-ma"))
        XCTAssertNil(missing)
    }

    func testRequestWithoutServerReplyEndsWithTimeoutInsteadOfHanging() async throws {
        // Serwer testowy nie odpowiada na otwarcie nieistniejącego katalogu — dokładnie ten przypadek wieszał klienta.
        let p = SFTPProvider(profile: profile(), context: ProviderContext(
            credentials: ConnectionCredentials(password: server.password), hostKeyVerifier: verifier()), operationTimeout: 1)
        try await p.connect()
        let started = Date()
        do { _ = try await p.list(RemotePath(parsing: "/nie-ma-takiego")); XCTFail("powinien być timeout lub błąd") }
        catch let e as NetworkError { XCTAssertTrue(e == .timeout || e == .connectionLost || { if case .notFound = e { return true }; return false }(), "\(e)") }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "operacja nie może wisieć")
        // po timeoucie sesja jest zamknięta — kolejne użycie zgłasza utratę połączenia (a menedżer połączy ponownie)
        do { _ = try await p.list(.root); XCTFail() } catch { XCTAssertEqual(error as? NetworkError, .connectionLost) }
    }

    // MARK: Silnik transferów na prawdziwym SFTP

    func testFullTreeUploadDownloadAndRemoteDeleteThroughEngine() async throws {
        let p = try await connected(); defer { Task { await p.disconnect() } }
        let id = UUID()
        let remote = RemoteTransferEngine(providerFor: { _ in p })
        let engine = FileOperationEngine(remote: remote)
        let tree = work.appendingPathComponent("projekt")
        try FileManager.default.createDirectory(at: tree.appendingPathComponent("src/głęboko"), withIntermediateDirectories: true)
        _ = try writeLocal("main.swift", bytes: 4000, in: tree.appendingPathComponent("src"))
        _ = try writeLocal("notatka ze spacją.md", bytes: 70_000, in: tree.appendingPathComponent("src/głęboko"))
        _ = try writeLocal("README", bytes: 10, in: tree)
        let dest = RemoteLocation(connectionID: id, path: .root).url

        var r = await engine.run(FileOperation(kind: .copy, sources: [tree], destination: dest))
        XCTAssertEqual(r.completedCount, 1, r.summary)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("projekt/src/głęboko/notatka ze spacją.md")).count, 70_000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tree.appendingPathComponent("README").path), "lokalne źródło zostaje")
        let left1 = try leftovers()
        XCTAssertTrue(left1.isEmpty, "brak plików tymczasowych na serwerze: \(left1)")

        // konflikt: domyślnie pomiń
        r = await engine.run(FileOperation(kind: .copy, sources: [tree], destination: dest))
        XCTAssertEqual(r.skippedCount, 1)

        // pobranie z powrotem do nowego katalogu i porównanie
        let dl = work.appendingPathComponent("pobrane"); try FileManager.default.createDirectory(at: dl, withIntermediateDirectories: true)
        r = await engine.run(FileOperation(kind: .copy, sources: [RemoteLocation(connectionID: id, path: RemotePath(parsing: "/projekt")).url], destination: dl))
        XCTAssertEqual(r.completedCount, 1, r.summary)
        XCTAssertEqual(try Data(contentsOf: dl.appendingPathComponent("projekt/README")), try Data(contentsOf: tree.appendingPathComponent("README")))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dl.path), ["projekt"], "bez śladów plików tymczasowych")

        // usuwanie na serwerze
        r = await engine.run(FileOperation(kind: .delete, sources: [RemoteLocation(connectionID: id, path: RemotePath(parsing: "/projekt")).url]))
        XCTAssertEqual(r.completedCount, 1, r.summary)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("projekt").path))
    }

    func testDeletingSymlinkOnServerKeepsTargetContents() async throws {
        let p = try await connected(); defer { Task { await p.disconnect() } }
        let cenny = root.appendingPathComponent("cenny"); try FileManager.default.createDirectory(at: cenny, withIntermediateDirectories: true)
        try Data("ważne".utf8).write(to: cenny.appendingPathComponent("plik.txt"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("lnk"), withDestinationURL: cenny)
        let id = UUID()
        let remote = RemoteTransferEngine(providerFor: { _ in p })
        let r = await FileOperationEngine(remote: remote).run(FileOperation(kind: .delete, sources: [RemoteLocation(connectionID: id, path: RemotePath(parsing: "/lnk")).url]))
        XCTAssertEqual(r.completedCount, 1, r.summary)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cenny.appendingPathComponent("plik.txt").path), "usunięcie dowiązania nie może ruszyć jego celu")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("lnk").path))
    }

    func testCancelDuringUploadLeavesNoFinalFileNorTemp() async throws {
        let p = try await connected(); defer { Task { await p.disconnect() } }
        let big = try writeLocal("duży.bin", bytes: 2_000_000)
        let box = TaskBox()
        let hooked = HookProvider(base: p) { sent in if sent > 100_000 { box.task?.cancel() } }
        let engine = FileOperationEngine(remote: RemoteTransferEngine(providerFor: { _ in hooked }))
        let dest = RemoteLocation(connectionID: UUID(), path: .root).url
        let task = Task { await engine.run(FileOperation(kind: .copy, sources: [big], destination: dest)) }
        box.task = task
        let r = await task.value
        XCTAssertEqual(r.cancelledCount, 1, r.summary)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("duży.bin").path))
        let left = try leftovers()
        XCTAssertTrue(left.isEmpty, "po anulowaniu sprzątamy własny plik tymczasowy: \(left)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: big.path))
    }

    func testServerDroppingMidUploadFailsCleanlyAndNeverLooksComplete() async throws {
        let proxy = try await TCPProxy(targetPort: server.port); defer { proxy.stop() }
        let base = SFTPProvider(profile: profile(port: proxy.port), context: ProviderContext(
            credentials: ConnectionCredentials(password: server.password), hostKeyVerifier: verifier()), operationTimeout: 5)
        try await base.connect(); defer { Task { await base.disconnect() } }
        let big = try writeLocal("duży.bin", bytes: 4_000_000)
        let fired = ProgressBox()
        let hooked = HookProvider(base: base) { sent in
            if sent > 200_000, fired.last == 0 { fired.last = 1; proxy.dropAll() }
        }
        let engine = FileOperationEngine(remote: RemoteTransferEngine(providerFor: { _ in hooked }))
        let dest = RemoteLocation(connectionID: UUID(), path: .root).url
        let r = await engine.run(FileOperation(kind: .copy, sources: [big], destination: dest))
        XCTAssertEqual(r.failures.count, 1, r.summary)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("duży.bin").path), "przerwany upload nie może wyglądać jak kompletny plik")
        XCTAssertTrue(FileManager.default.fileExists(atPath: big.path))
        let msg = r.failures.first.map { $0.1.localizedDescription } ?? ""
        XCTAssertFalse(msg.contains(server.password))
    }

    // MARK: Menedżer połączeń end-to-end

    @MainActor func testConnectionManagerTestAndSessionAgainstRealServer() async throws {
        let secrets = InMemorySecretStore()
        let m = ConnectionManager(profileStore: ProfileStore(defaults: UserDefaults(suiteName: "oc-sftp-\(UUID().uuidString)")!, key: "p"),
                                  secrets: secrets, trustedHostsStore: TrustedHostsStore(url: hostsURL))
        RemoteModule.install(in: m)
        m.hostKeyPrompt = { _ in true }
        let ok = await m.test(profile(), password: server.password, passphrase: nil)
        guard case .success(let text) = ok else { return XCTFail("\(ok)") }
        XCTAssertTrue(text.contains("Połączono"))
        let bad = await m.test(profile(), password: "zle-haslo-zle", passphrase: nil)
        guard case .failure(let e) = bad else { return XCTFail() }
        XCTAssertEqual(e, .authenticationFailed)
        let saved = try m.save(profile(), password: server.password)
        let provider = try await m.provider(for: saved.id)
        let rootCount = try await provider.list(.root).count
        XCTAssertEqual(rootCount, 0)
        XCTAssertEqual(m.state(saved.id), .connected)
        await m.disconnect(saved.id)
        XCTAssertEqual(m.state(saved.id), .disconnected)
    }

    private func leftovers() throws -> [String] {
        let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        return (en?.allObjects as? [URL] ?? []).map(\.lastPathComponent).filter { $0.hasPrefix(".opencommander-tmp-") }
    }
}

final class ProgressBox: @unchecked Sendable { private let l = NSLock(); private var v: Int64 = 0
    var last: Int64 { get { l.withLock { v } } set { l.withLock { v = newValue } } } }
final class TaskBox: @unchecked Sendable { private let l = NSLock(); private var t: Task<OperationReport, Never>?
    var task: Task<OperationReport, Never>? { get { l.withLock { t } } set { l.withLock { t = newValue } } } }

