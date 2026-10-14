import XCTest
@testable import OpenCommanderCore

final class RemoteTransferTests: TempDirTestCase {
    var provider: FakeProvider!
    var trasher: FakeTrasher!
    var connID = UUID()

    override func setUpWithError() throws {
        try super.setUpWithError()
        provider = FakeProvider()
        trasher = FakeTrasher(bin: bin)
    }

    private func engine(journal: TempJournal? = nil) -> FileOperationEngine {
        let p = provider!, id = connID
        let remote = RemoteTransferEngine(providerFor: { requested in
            guard requested == id else { throw NetworkError.notFound("połączenie") }
            return p
        }, trasher: trasher, journal: journal)
        return FileOperationEngine(trasher: trasher, journal: journal, remote: remote)
    }

    private func remoteURL(_ path: String) -> URL { RemoteLocation(connectionID: connID, path: RemotePath(parsing: path)).url }

    private func run(_ op: FileOperation, decide: ConflictResolution = .skip, all: Bool = false) async -> OperationReport {
        await engine().run(op, conflictHandler: { _ in ConflictDecision(decide, applyToAll: all) })
    }

    // MARK: Upload

    func testUploadFileAndFolderKeepsLocalSourceAndLeavesNoTemp() async throws {
        let f = try makeFile("lok/a.txt", "AAA")
        try makeFile("lok/dir/b.txt", "BBB"); try makeFile("lok/dir/sub/c.txt", "CCC")
        provider.seedDir("/in")
        let r = await run(FileOperation(kind: .copy, sources: [f, root.appendingPathComponent("lok/dir")], destination: remoteURL("/in")))
        XCTAssertEqual(r.completedCount, 2, r.summary)
        XCTAssertEqual(provider.contents("/in/a.txt"), "AAA")
        XCTAssertEqual(provider.contents("/in/dir/b.txt"), "BBB")
        XCTAssertEqual(provider.contents("/in/dir/sub/c.txt"), "CCC")
        XCTAssertTrue(provider.tempLeftovers.isEmpty, "po sukcesie nie zostają pliki tymczasowe: \(provider.tempLeftovers)")
        XCTAssertEqual(read(f), "AAA", "lokalne źródło zostaje po uploadzie")
        XCTAssertTrue(exists(root.appendingPathComponent("lok/dir/b.txt")))
    }

    func testUploadSkipsSymlinksAndUnicodeNamesWork() async throws {
        let dir = try makeDir("lok/Żółć ĄĘ #1")
        try makeFile("lok/Żółć ĄĘ #1/zażółć gęślą.txt", "ok")
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("link"), withDestinationURL: root)
        provider.seedDir("/in")
        let r = await run(FileOperation(kind: .copy, sources: [dir], destination: remoteURL("/in")))
        XCTAssertEqual(r.completedCount, 1)
        XCTAssertEqual(provider.contents("/in/Żółć ĄĘ #1/zażółć gęślą.txt"), "ok")
        XCTAssertFalse(provider.has("/in/Żółć ĄĘ #1/link"), "dowiązań lokalnych nie wysyłamy")
    }

    func testUploadConflictDefaultSkipNeverOverwrites() async throws {
        let f = try makeFile("lok/a.txt", "NOWY")
        provider.seedFile("/in/a.txt", "STARY")
        let r = await run(FileOperation(kind: .copy, sources: [f], destination: remoteURL("/in")), decide: .skip)
        XCTAssertEqual(r.skippedCount, 1)
        XCTAssertEqual(provider.contents("/in/a.txt"), "STARY")
        XCTAssertTrue(provider.tempLeftovers.isEmpty)
    }

    func testUploadKeepBothUsesFreeName() async throws {
        let f = try makeFile("lok/a.txt", "NOWY")
        provider.seedFile("/in/a.txt", "STARY"); provider.seedFile("/in/a kopia.txt", "KOPIA1")
        let r = await run(FileOperation(kind: .copy, sources: [f], destination: remoteURL("/in")), decide: .keepBoth)
        XCTAssertEqual(r.completedCount, 1)
        XCTAssertEqual(provider.contents("/in/a.txt"), "STARY")
        XCTAssertEqual(provider.contents("/in/a kopia.txt"), "KOPIA1")
        XCTAssertEqual(provider.contents("/in/a kopia 2.txt"), "NOWY")
    }

    func testUploadReplaceIsExplicitAndSwapsViaTempFile() async throws {
        let f = try makeFile("lok/a.txt", "NOWY")
        provider.seedFile("/in/a.txt", "STARY")
        let r = await run(FileOperation(kind: .copy, sources: [f], destination: remoteURL("/in")), decide: .replace)
        XCTAssertEqual(r.completedCount, 1)
        XCTAssertEqual(provider.contents("/in/a.txt"), "NOWY")
        let log = provider.logLines
        let up = log.firstIndex { $0.hasPrefix("upload") && $0.contains(".opencommander-tmp-") }
        let del = log.firstIndex { $0 == "delete /in/a.txt" }
        XCTAssertNotNil(up); XCTAssertNotNil(del)
        XCTAssertLessThan(up!, del!, "nowa wersja jest wysłana, zanim stara zostanie usunięta")
        XCTAssertTrue(provider.tempLeftovers.isEmpty)
    }

    func testUploadReplaceOfRemoteFolderIsRefused() async throws {
        let d = try makeDir("lok/dir"); try makeFile("lok/dir/x.txt")
        provider.seedFile("/in/dir/ważne.txt", "WAŻNE")
        let r = await run(FileOperation(kind: .copy, sources: [d], destination: remoteURL("/in")), decide: .replace)
        XCTAssertEqual(r.failures.count, 1)
        XCTAssertEqual(provider.contents("/in/dir/ważne.txt"), "WAŻNE", "zawartość folderu na serwerze nietknięta")
    }

    func testFailedUploadLeavesNoPartialFinalFile() async throws {
        let f = try makeFile("lok/duży.bin", String(repeating: "z", count: 100))
        provider.seedDir("/in"); provider.failUploadAfterBytes = 10
        let r = await run(FileOperation(kind: .copy, sources: [f], destination: remoteURL("/in")))
        XCTAssertEqual(r.failures.count, 1)
        XCTAssertFalse(provider.has("/in/duży.bin"), "przerwany upload nie może wyglądać jak kompletny plik")
        XCTAssertTrue(provider.tempLeftovers.isEmpty, "własny plik tymczasowy na serwerze posprzątany: \(provider.tempLeftovers)")
        XCTAssertTrue(exists(f))
    }

    func testCancelledUploadCleansUpAndReportsCancelled() async throws {
        let f = try makeFile("lok/a.txt", "AAA")
        provider.seedDir("/in"); provider.uploadDelay = 2
        let eng = engine()
        let task = Task { await eng.run(FileOperation(kind: .copy, sources: [f], destination: self.remoteURL("/in"))) }
        try await Task.sleep(nanoseconds: 150_000_000)
        task.cancel()
        let r = await task.value
        XCTAssertEqual(r.cancelledCount, 1, r.summary)
        XCTAssertFalse(provider.has("/in/a.txt"))
        XCTAssertTrue(provider.tempLeftovers.isEmpty)
    }

    func testServerSizeMismatchFailsUploadAndRemovesTemp() async throws {
        let f = try makeFile("lok/a.txt", "AAAA")
        provider.seedDir("/in"); provider.failUploadAfterBytes = nil
        // provider zapisuje mniej bajtów, ale nie zgłasza błędu → silnik musi to wychwycić
        provider.failUploadWith = NetworkError.cancelled
        let short = ShortWritingProvider(wrapping: provider)
        let remote = RemoteTransferEngine(providerFor: { _ in short }, trasher: trasher)
        let r = await FileOperationEngine(trasher: trasher, remote: remote)
            .run(FileOperation(kind: .copy, sources: [f], destination: remoteURL("/in")))
        XCTAssertEqual(r.failures.count, 1, r.summary)
        XCTAssertFalse(provider.has("/in/a.txt"))
        XCTAssertTrue(provider.tempLeftovers.isEmpty)
    }

    // MARK: Download

    func testDownloadFileAndFolderViaTempWithJournalClean() async throws {
        provider.seedFile("/d/a.txt", "AAA"); provider.seedFile("/d/dir/b.txt", "BBB"); provider.seedFile("/d/dir/sub/c.txt", "CCC")
        let dest = try makeDir("pobrane")
        let journal = TempJournal(fileURL: root.appendingPathComponent("journal.json"))
        let r = await engine(journal: journal).run(FileOperation(kind: .copy, sources: [remoteURL("/d/a.txt"), remoteURL("/d/dir")], destination: dest))
        XCTAssertEqual(r.completedCount, 2, r.summary)
        XCTAssertEqual(read(dest.appendingPathComponent("a.txt")), "AAA")
        XCTAssertEqual(read(dest.appendingPathComponent("dir/sub/c.txt")), "CCC")
        XCTAssertEqual(names(dest), ["a.txt", "dir"], "brak śladów plików tymczasowych")
        let journalText = (try? String(contentsOf: root.appendingPathComponent("journal.json"), encoding: .utf8)) ?? ""
        XCTAssertFalse(journalText.contains(".opencommander-tmp-"), "dziennik nie trzyma wpisów po sukcesie")
        XCTAssertTrue(journal.sweep().isEmpty)
    }

    func testIncompleteDownloadIsRejectedAndLeavesNothing() async throws {
        provider.seedFile("/d/a.bin", "0123456789"); provider.corruptDownloads = true
        let dest = try makeDir("pobrane")
        let r = await run(FileOperation(kind: .copy, sources: [remoteURL("/d/a.bin")], destination: dest))
        XCTAssertEqual(r.failures.count, 1)
        XCTAssertEqual(names(dest), [], "niekompletny plik nie może się pojawić ani zostać jako tymczasowy")
    }

    func testMaliciousNamesFromServerAreBlockedDuringDownload() async throws {
        provider.seedDir("/d/evil")
        provider.injectedListNames["/d/evil"] = [
            RemoteEntry(name: "../../uciekinier.txt", kind: .file, size: 1),
            RemoteEntry(name: "..", kind: .directory),
            RemoteEntry(name: "a/b", kind: .file, size: 1),
            RemoteEntry(name: "ok.txt", kind: .file, size: 2),
        ]
        provider.seedFile("/d/evil/ok.txt", "OK")
        let dest = try makeDir("pobrane")
        let r = await run(FileOperation(kind: .copy, sources: [remoteURL("/d/evil")], destination: dest))
        XCTAssertEqual(r.failures.count, 1, "folder z podejrzanymi nazwami kończy się zgłoszeniem problemu")
        XCTAssertFalse(exists(root.appendingPathComponent("uciekinier.txt")))
        XCTAssertFalse(exists(dest.deletingLastPathComponent().appendingPathComponent("uciekinier.txt")))
        XCTAssertFalse(exists(dest.appendingPathComponent("evil")), "nic nie jest finalizowane, gdy część elementów odrzucono? — folder nie może zostać")
    }

    func testRemoteSymlinksAreNotFollowedInFoldersButExplicitFileSymlinkIsAllowed() async throws {
        provider.seedFile("/d/dir/real.txt", "R"); provider.seedSymlink("/d/dir/lnk-dir", targetIsDir: true)
        provider.seedSymlink("/d/lnk-file", targetIsDir: false); provider.seedSymlink("/d/lnk-dir2", targetIsDir: true)
        provider.seedFile("/d/lnk-file", "x")   // nadpisuje symlink plikiem testowym, by stat zwrócił plik
        let dest = try makeDir("pobrane")
        let r = await run(FileOperation(kind: .copy, sources: [remoteURL("/d/dir"), remoteURL("/d/lnk-dir2")], destination: dest))
        XCTAssertEqual(r.completedCount, 1); XCTAssertEqual(r.skippedCount, 1)
        XCTAssertEqual(names(dest.appendingPathComponent("dir")), ["real.txt"], "dowiązanie do folderu pominięte w środku")
    }

    func testDownloadConflictSkipKeepBothReplace() async throws {
        provider.seedFile("/d/a.txt", "SERWER")
        let dest = try makeDir("pobrane"); try makeFile("pobrane/a.txt", "LOKALNY")
        var r = await run(FileOperation(kind: .copy, sources: [remoteURL("/d/a.txt")], destination: dest), decide: .skip)
        XCTAssertEqual(r.skippedCount, 1); XCTAssertEqual(read(dest.appendingPathComponent("a.txt")), "LOKALNY")
        r = await run(FileOperation(kind: .copy, sources: [remoteURL("/d/a.txt")], destination: dest), decide: .keepBoth)
        XCTAssertEqual(read(dest.appendingPathComponent("a.txt")), "LOKALNY")
        XCTAssertEqual(read(dest.appendingPathComponent("a kopia.txt")), "SERWER")
        r = await run(FileOperation(kind: .copy, sources: [remoteURL("/d/a.txt")], destination: dest), decide: .replace)
        XCTAssertEqual(read(dest.appendingPathComponent("a.txt")), "SERWER")
        XCTAssertEqual(trasher.trashed.count, 1, "zastępowany lokalny plik trafia do Kosza (atrapy)")
    }

    func testMissingRemoteSourceIsReported() async throws {
        let dest = try makeDir("pobrane")
        let r = await run(FileOperation(kind: .copy, sources: [remoteURL("/nie/ma")], destination: dest))
        XCTAssertEqual(r.failures.count, 1)
        XCTAssertTrue(r.failures[0].1.localizedDescription.contains("nie istnieje"))
    }

    // MARK: Usuwanie i zakazane kombinacje

    func testRemoteDeleteRemovesTreeDepthFirstAndMissingIsSkipped() async throws {
        provider.seedFile("/x/dir/a.txt", "1"); provider.seedFile("/x/dir/sub/b.txt", "2"); provider.seedFile("/x/keep.txt", "3")
        let r = await run(FileOperation(kind: .delete, sources: [remoteURL("/x/dir"), remoteURL("/x/nie-ma")]))
        XCTAssertEqual(r.completedCount, 1); XCTAssertEqual(r.skippedCount, 1)
        XCTAssertFalse(provider.has("/x/dir")); XCTAssertFalse(provider.has("/x/dir/sub/b.txt"))
        XCTAssertTrue(provider.has("/x/keep.txt"))
    }

    func testDeleteNeverFollowsSymlinks() async throws {
        provider.seedFile("/real/cenne.txt", "!"); provider.seedDir("/x"); provider.seedSymlink("/x/lnk", targetIsDir: true)
        let r = await run(FileOperation(kind: .delete, sources: [remoteURL("/x/lnk")]))
        XCTAssertEqual(r.completedCount, 1)
        XCTAssertTrue(provider.has("/real/cenne.txt"), "cel dowiązania nietknięty")
    }

    func testMoveTrashAndServerToServerAreRefused() async throws {
        provider.seedFile("/a/f.txt", "x"); provider.seedDir("/b")
        let local = try makeFile("lok/a.txt")
        let ops = [
            FileOperation(kind: .move, sources: [remoteURL("/a/f.txt")], destination: try makeDir("pobrane")),
            FileOperation(kind: .move, sources: [local], destination: remoteURL("/b")),
            FileOperation(kind: .trash, sources: [remoteURL("/a/f.txt")]),
            FileOperation(kind: .copy, sources: [remoteURL("/a/f.txt")], destination: remoteURL("/b")),
        ]
        for op in ops {
            let r = await run(op)
            XCTAssertEqual(r.failures.count, 1, "\(op.kind) powinno zostać odrzucone")
        }
        XCTAssertTrue(provider.has("/a/f.txt")); XCTAssertTrue(exists(local)); XCTAssertEqual(provider.logLines.filter { $0.hasPrefix("upload") || $0.hasPrefix("delete") }.count, 0)
    }

    func testWithoutRemoteHandlerRemoteOperationsFailSafely() async throws {
        let plain = FileOperationEngine(trasher: trasher)
        let r = await plain.run(FileOperation(kind: .delete, sources: [remoteURL("/a")]))
        XCTAssertEqual(r.failures.count, 1)
    }

    func testProviderErrorTextsAreRedacted() async throws {
        provider.seedDir("/in"); let f = try makeFile("lok/a.txt")
        provider.failUploadAfterBytes = 0
        provider.failUploadWith = NetworkError.other("serwer: login ftp://ola:Hunter22@host password=Hunter22 Authorization: Basic b2xhOkh1bnRlcjIy")
        let r = await run(FileOperation(kind: .copy, sources: [f], destination: remoteURL("/in")))
        let msg = r.failures.first.map { $0.1.localizedDescription } ?? ""
        XCTAssertFalse(msg.contains("Hunter22")); XCTAssertFalse(msg.contains("b2xhOkh1"))
        XCTAssertFalse(msg.isEmpty)
    }

    func testRetryFailedRequeuesOnlyFailedItemsFromScratch() async throws {
        provider.seedDir("/in")
        let ok = try makeFile("lok/ok.txt", "OK"), bad = try makeFile("lok/bad.txt", String(repeating: "b", count: 50))
        provider.failUploadAfterBytes = 10
        let remote = RemoteTransferEngine(providerFor: { [p = provider!] _ in p }, trasher: trasher)
        let center = await OperationCenter(engine: FileOperationEngine(trasher: trasher, remote: remote))
        await center.enqueue(FileOperation(kind: .copy, sources: [ok, bad], destination: remoteURL("/in")))
        await center.waitUntilIdle()
        let first = await center.jobs[0]
        XCTAssertEqual(first.state, .completedWithIssues)
        provider.failUploadAfterBytes = nil
        let queued = await center.retryFailed(first.id)
        XCTAssertTrue(queued)
        await center.waitUntilIdle()
        let second = await center.jobs[1]
        XCTAssertEqual(second.operation.sources, [bad], "ponawiamy tylko nieudane elementy")
        XCTAssertEqual(provider.contents("/in/bad.txt"), String(repeating: "b", count: 50))
    }
}

/// Provider, który „po cichu” zapisuje o bajt mniej — symulacja uciętego transferu bez zgłoszenia błędu.
final class ShortWritingProvider: FileProvider, @unchecked Sendable {
    let base: FakeProvider
    init(wrapping base: FakeProvider) { self.base = base }
    var capabilities: ProviderCapabilities { base.capabilities }
    func connect() async throws {}
    func disconnect() async {}
    func initialPath() async throws -> RemotePath { .root }
    func list(_ p: RemotePath) async throws -> [RemoteEntry] { try await base.list(p) }
    func stat(_ p: RemotePath) async throws -> RemoteEntry? { try await base.stat(p) }
    func download(_ p: RemotePath, to l: URL, progress: @escaping @Sendable (Int64) -> Void) async throws { try await base.download(p, to: l, progress: progress) }
    func upload(from l: URL, to p: RemotePath, overwrite: Bool, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let data = try Data(contentsOf: l).dropLast()
        let tmpLocal = l.deletingLastPathComponent().appendingPathComponent(".short-\(UUID().uuidString)")
        try Data(data).write(to: tmpLocal); defer { try? FileManager.default.removeItem(at: tmpLocal) }
        try await base.upload(from: tmpLocal, to: p, overwrite: overwrite, progress: progress)
    }
    func makeDirectory(_ p: RemotePath) async throws { try await base.makeDirectory(p) }
    func rename(_ a: RemotePath, to b: RemotePath) async throws { try await base.rename(a, to: b) }
    func delete(_ p: RemotePath, isDirectory: Bool) async throws { try await base.delete(p, isDirectory: isDirectory) }
}
