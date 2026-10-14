import XCTest
@testable import OpenCommanderCore

final class EngineTests: TempDirTestCase {
    func engine(cross: Bool = false) -> (FileOperationEngine, FakeTrasher) {
        let t = FakeTrasher(bin: bin)
        return (FileOperationEngine(trasher: t, forceCrossVolumeMove: cross), t)
    }

    func run(_ op: FileOperation, _ e: FileOperationEngine, decision: ConflictDecision? = nil) async -> OperationReport {
        await e.run(op, conflictHandler: { _ in decision ?? ConflictDecision(.skip) })
    }

    // MARK: kopiowanie

    func testCopyFileAndFolderTree() async throws {
        let f = try makeFile("src/a.txt", "A")
        try makeFile("src/tree/b/c.txt", "C"); try makeFile("src/tree/d.txt", "D")
        let dest = try makeDir("dest")
        let (e, _) = engine()
        let r = await run(FileOperation(kind: .copy, sources: [f, root.appendingPathComponent("src/tree")], destination: dest), e)
        XCTAssertEqual(r.completedCount, 2); XCTAssertTrue(r.failures.isEmpty)
        XCTAssertEqual(read(dest.appendingPathComponent("a.txt")), "A")
        XCTAssertEqual(read(dest.appendingPathComponent("tree/b/c.txt")), "C")
        XCTAssertEqual(read(f), "A", "źródło zostaje po kopiowaniu")
        XCTAssertEqual(names(dest), ["a.txt", "tree"], "brak plików tymczasowych")
    }

    func testCopyUnicodeNames() async throws {
        let f = try makeFile("src/zażółć 🎵 ü.txt", "u"); let dest = try makeDir("dest")
        let (e, _) = engine()
        _ = await run(FileOperation(kind: .copy, sources: [f], destination: dest), e)
        XCTAssertEqual(read(dest.appendingPathComponent("zażółć 🎵 ü.txt")), "u")
    }

    func testCopyPreservesSymlinkAsLink() async throws {
        let target = try makeFile("src/real.txt", "R"); let dest = try makeDir("dest")
        let link = root.appendingPathComponent("src/link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let (e, _) = engine()
        _ = await run(FileOperation(kind: .copy, sources: [link], destination: dest), e)
        let copied = dest.appendingPathComponent("link")
        XCTAssertEqual((try? FileManager.default.destinationOfSymbolicLink(atPath: copied.path)), target.path,
                       "dowiązanie ma zostać dowiązaniem, a nie kopią celu")
    }

    func testCopyBrokenSymlinkWorks() async throws {
        let dest = try makeDir("dest"); try makeDir("src")
        let link = root.appendingPathComponent("src/broken")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("nope"))
        let (e, _) = engine()
        let r = await run(FileOperation(kind: .copy, sources: [link], destination: dest), e)
        XCTAssertEqual(r.completedCount, 1)
    }

    // MARK: konflikty

    func testConflictSkipKeepsExisting() async throws {
        let f = try makeFile("src/a.txt", "NEW"); let dest = try makeDir("dest"); try makeFile("dest/a.txt", "OLD")
        let (e, t) = engine()
        let r = await run(FileOperation(kind: .copy, sources: [f], destination: dest), e, decision: ConflictDecision(.skip))
        XCTAssertEqual(r.skippedCount, 1)
        XCTAssertEqual(read(dest.appendingPathComponent("a.txt")), "OLD"); XCTAssertTrue(t.trashed.isEmpty)
    }

    func testConflictKeepBoth() async throws {
        let f = try makeFile("src/a.txt", "NEW"); let dest = try makeDir("dest"); try makeFile("dest/a.txt", "OLD")
        let (e, _) = engine()
        _ = await run(FileOperation(kind: .copy, sources: [f], destination: dest), e, decision: ConflictDecision(.keepBoth))
        XCTAssertEqual(read(dest.appendingPathComponent("a.txt")), "OLD")
        XCTAssertEqual(read(dest.appendingPathComponent("a kopia.txt")), "NEW")
        _ = await run(FileOperation(kind: .copy, sources: [f], destination: dest), e, decision: ConflictDecision(.keepBoth))
        XCTAssertEqual(read(dest.appendingPathComponent("a kopia 2.txt")), "NEW")
    }

    func testConflictReplaceSendsOldToTrash() async throws {
        let f = try makeFile("src/a.txt", "NEW"); let dest = try makeDir("dest"); try makeFile("dest/a.txt", "OLD")
        let (e, t) = engine()
        let r = await run(FileOperation(kind: .copy, sources: [f], destination: dest), e, decision: ConflictDecision(.replace))
        XCTAssertEqual(r.completedCount, 1)
        XCTAssertEqual(read(dest.appendingPathComponent("a.txt")), "NEW")
        XCTAssertEqual(t.trashed.count, 1, "zastąpiony element trafia do Kosza, nie jest kasowany")
        let inBin = names(bin)
        XCTAssertEqual(inBin.count, 1); XCTAssertEqual(read(bin.appendingPathComponent(inBin[0])), "OLD")
    }

    func testReplaceAbortsWhenTrashFails() async throws {
        let f = try makeFile("src/a.txt", "NEW"); let dest = try makeDir("dest"); try makeFile("dest/a.txt", "OLD")
        let (e, t) = engine(); t.shouldFail = true
        let r = await run(FileOperation(kind: .copy, sources: [f], destination: dest), e, decision: ConflictDecision(.replace))
        XCTAssertEqual(r.failures.count, 1)
        XCTAssertEqual(read(dest.appendingPathComponent("a.txt")), "OLD")
        XCTAssertEqual(names(dest), ["a.txt"], "plik tymczasowy posprzątany")
    }

    func testApplyToAllAsksOnce() async throws {
        let a = try makeFile("src/a.txt", "1"), b = try makeFile("src/b.txt", "2")
        let dest = try makeDir("dest"); try makeFile("dest/a.txt", "x"); try makeFile("dest/b.txt", "y")
        let (e, _) = engine()
        let counter = Counter()
        let r = await e.run(FileOperation(kind: .copy, sources: [a, b], destination: dest),
                            conflictHandler: { _ in await counter.bump(); return ConflictDecision(.skip, applyToAll: true) })
        let asked = await counter.value
        XCTAssertEqual(asked, 1); XCTAssertEqual(r.skippedCount, 2)
    }

    func testCopyOntoItselfInSameFolderWithReplaceIsRefused() async throws {
        let f = try makeFile("a.txt", "A")
        let (e, t) = engine()
        let r = await run(FileOperation(kind: .copy, sources: [f], destination: root), e, decision: ConflictDecision(.replace))
        XCTAssertEqual(r.failures.first?.1, .replaceWouldDestroySource("a.txt"))
        XCTAssertEqual(read(f), "A"); XCTAssertTrue(t.trashed.isEmpty)
    }

    func testCopyInSameFolderKeepBothDuplicates() async throws {
        let f = try makeFile("a.txt", "A")
        let (e, _) = engine()
        _ = await run(FileOperation(kind: .copy, sources: [f], destination: root), e, decision: ConflictDecision(.keepBoth))
        XCTAssertEqual(names(root), ["a kopia.txt", "a.txt"])
    }

    func testKeepBothForFolderDoesNotSplitExtension() async throws {
        let d = try makeDir("src/my.folder"); try makeFile("src/my.folder/x", "x")
        let dest = try makeDir("dest"); try makeDir("dest/my.folder")
        let (e, _) = engine()
        _ = await run(FileOperation(kind: .copy, sources: [d], destination: dest), e, decision: ConflictDecision(.keepBoth))
        XCTAssertEqual(names(dest), ["my.folder", "my.folder kopia"])
    }

    // MARK: bezpieczeństwo

    func testCopyFolderIntoItselfAndDescendantRefused() async throws {
        let d = try makeDir("top"); let child = try makeDir("top/child"); try makeFile("top/f.txt")
        let (e, _) = engine()
        for dest in [d, child] {
            for kind in [OperationKind.copy, .move] {
                let r = await run(FileOperation(kind: kind, sources: [d], destination: dest), e)
                XCTAssertEqual(r.failures.first?.1, .copyIntoItself("top"), "\(kind) → \(dest.lastPathComponent)")
            }
        }
        XCTAssertEqual(names(d), ["child", "f.txt"], "nic się nie zmieniło")
    }

    func testCopyIntoDescendantViaSymlinkRefused() async throws {
        let d = try makeDir("top"); try makeDir("top/child")
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: d.appendingPathComponent("child"))
        let (e, _) = engine()
        let r = await run(FileOperation(kind: .copy, sources: [d], destination: alias), e)
        XCTAssertEqual(r.failures.first?.1, .copyIntoItself("top"))
    }

    func testMissingSourceReported() async throws {
        let dest = try makeDir("dest"); let ok = try makeFile("ok.txt", "ok")
        let (e, _) = engine()
        let r = await run(FileOperation(kind: .copy, sources: [root.appendingPathComponent("ghost.txt"), ok], destination: dest), e)
        XCTAssertEqual(r.failures.first?.1, .sourceMissing("ghost.txt"))
        XCTAssertEqual(r.completedCount, 1, "kolejne elementy nadal wykonane")
    }

    func testMissingDestinationReported() async throws {
        let f = try makeFile("a.txt")
        let (e, _) = engine()
        let r = await run(FileOperation(kind: .copy, sources: [f], destination: root.appendingPathComponent("nope")), e)
        XCTAssertEqual(r.failures.first?.1, .destinationUnavailable("nope"))
    }

    func testSourceSurvivesFailedCopyAndMove() async throws {
        let f = try makeFile("src/secret.txt", "S"); let dest = try makeDir("dest")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: f.path)
        let (e, _) = engine(cross: true)
        for kind in [OperationKind.copy, .move] {
            let r = await run(FileOperation(kind: kind, sources: [f], destination: dest), e)
            XCTAssertEqual(r.failures.count, 1, "\(kind)")
        }
        XCTAssertTrue(exists(f), "źródło musi przetrwać nieudane kopiowanie")
        XCTAssertEqual(names(dest), [], "brak śmieci po nieudanej kopii")
    }

    func testDestinationReadOnlyDoesNotLoseSource() async throws {
        let f = try makeFile("src/a.txt", "A"); let dest = try makeDir("dest")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dest.path)
        let (e, _) = engine()
        let r = await run(FileOperation(kind: .move, sources: [f], destination: dest), e)
        XCTAssertEqual(r.failures.count, 1)
        XCTAssertEqual(read(f), "A")
    }

    // MARK: przenoszenie

    func testMoveSameVolume() async throws {
        let f = try makeFile("src/a.txt", "A"); try makeFile("src/dir/b.txt", "B"); let dest = try makeDir("dest")
        let (e, _) = engine()
        let r = await run(FileOperation(kind: .move, sources: [f, root.appendingPathComponent("src/dir")], destination: dest), e)
        XCTAssertEqual(r.completedCount, 2)
        XCTAssertFalse(exists(f)); XCTAssertEqual(read(dest.appendingPathComponent("dir/b.txt")), "B")
        XCTAssertEqual(names(dest), ["a.txt", "dir"])
    }

    func testMoveCrossVolumePathCopiesThenRemovesSource() async throws {
        let f = try makeFile("src/a.txt", "A"); try makeFile("src/dir/b.txt", "B"); let dest = try makeDir("dest")
        let (e, _) = engine(cross: true)
        let r = await run(FileOperation(kind: .move, sources: [f, root.appendingPathComponent("src/dir")], destination: dest), e)
        XCTAssertEqual(r.completedCount, 2)
        XCTAssertFalse(exists(f)); XCTAssertFalse(exists(root.appendingPathComponent("src/dir")))
        XCTAssertEqual(read(dest.appendingPathComponent("a.txt")), "A")
        XCTAssertEqual(read(dest.appendingPathComponent("dir/b.txt")), "B")
    }

    func testMoveToSameFolderIsNoOp() async throws {
        let f = try makeFile("a.txt", "A")
        let (e, _) = engine()
        let r = await run(FileOperation(kind: .move, sources: [f], destination: root), e)
        XCTAssertEqual(r.skippedCount, 1); XCTAssertEqual(read(f), "A")
    }

    func testMoveWithReplaceRestoresSourceWhenTrashFails() async throws {
        let f = try makeFile("src/a.txt", "NEW"); let dest = try makeDir("dest"); try makeFile("dest/a.txt", "OLD")
        let (e, t) = engine(); t.shouldFail = true
        let r = await run(FileOperation(kind: .move, sources: [f], destination: dest), e, decision: ConflictDecision(.replace))
        XCTAssertEqual(r.failures.count, 1)
        XCTAssertEqual(read(f), "NEW", "źródło wraca na miejsce"); XCTAssertEqual(read(dest.appendingPathComponent("a.txt")), "OLD")
        XCTAssertEqual(names(dest), ["a.txt"])
    }

    // MARK: kosz

    func testTrashUsesInjectedTrasherAndReportsMissing() async throws {
        let f = try makeFile("a.txt")
        let (e, t) = engine()
        let r = await run(FileOperation(kind: .trash, sources: [f, root.appendingPathComponent("ghost")]), e)
        XCTAssertEqual(r.completedCount, 1); XCTAssertEqual(r.failures.first?.1, .sourceMissing("ghost"))
        XCTAssertEqual(t.trashed, [f]); XCTAssertFalse(exists(f))
    }

    // MARK: anulowanie

    func testCancelledBeforeStartChangesNothing() async throws {
        let f = try makeFile("src/a.txt"); let dest = try makeDir("dest")
        let (e, _) = engine()
        let op = FileOperation(kind: .copy, sources: [f], destination: dest)
        let task = Task { () -> OperationReport in
            withUnsafeCurrentTask { $0?.cancel() }
            return await e.run(op)
        }
        let r = await task.value
        XCTAssertEqual(r.cancelledCount, 1); XCTAssertEqual(names(dest), [])
    }

    func testCancelBetweenItems() async throws {
        let a = try makeFile("src/a.txt"), b = try makeFile("src/b.txt"), dest = try makeDir("dest")
        let (e, _) = engine()
        let op = FileOperation(kind: .copy, sources: [a, b], destination: dest)
        let holder = TaskHolder()
        let task = Task { () -> OperationReport in
            await e.run(op, progress: { p in if p.completedItems == 1 { holder.cancel() } })
        }
        holder.set(task)
        let r = await task.value
        XCTAssertEqual(r.completedCount, 1); XCTAssertEqual(r.cancelledCount, 1)
        XCTAssertEqual(names(dest), ["a.txt"])
    }
}

actor Counter { var value = 0; func bump() { value += 1 } }
final class TaskHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<OperationReport, Never>?
    func set(_ t: Task<OperationReport, Never>) { lock.lock(); task = t; lock.unlock() }
    func cancel() { lock.lock(); let t = task; lock.unlock(); t?.cancel() }
}

final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [OperationProgress] = []
    func add(_ p: OperationProgress) { lock.lock(); items.append(p); lock.unlock() }
    var all: [OperationProgress] { lock.lock(); defer { lock.unlock() }; return items }
}

/// Postęp bajtowy i anulowanie w środku pliku (klonowanie APFS wyłączone, by dane faktycznie płynęły).
final class ByteProgressTests: TempDirTestCase {
    func bigFile(_ rel: String, mb: Int) throws -> URL {
        let u = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data(count: mb * 1024 * 1024)
        data.withUnsafeMutableBytes { buf in for i in stride(from: 0, to: buf.count, by: 4096) { buf[i] = UInt8(truncatingIfNeeded: i >> 12) } }
        try data.write(to: u)
        return u
    }

    func engine() -> FileOperationEngine {
        FileOperationEngine(trasher: FakeTrasher(bin: bin), allowClone: false, progressInterval: 0)
    }

    func testByteProgressIsMonotonicAndReachesTotal() async throws {
        let f = try bigFile("src/big.bin", mb: 96); let dest = try makeDir("dest")
        let log = ProgressLog()
        let r = await engine().run(FileOperation(kind: .copy, sources: [f], destination: dest), progress: { log.add($0) })
        XCTAssertEqual(r.completedCount, 1)
        let all = log.all
        let total = Int64(96 * 1024 * 1024)
        XCTAssertEqual(all.last?.bytesDone, total); XCTAssertEqual(all.last?.totalBytes, total)
        XCTAssertTrue(zip(all, all.dropFirst()).allSatisfy { $0.bytesDone <= $1.bytesDone }, "postęp nie cofa się")
        XCTAssertTrue(all.contains { $0.bytesDone > 0 && $0.bytesDone < total }, "są postępy pośrednie w trakcie jednego pliku")
        XCTAssertEqual(try Data(contentsOf: f), try Data(contentsOf: dest.appendingPathComponent("big.bin")))
    }

    func testFolderTotalBytesAndLinksPreserved() async throws {
        try bigFile("src/tree/a.bin", mb: 3); try bigFile("src/tree/sub/b.bin", mb: 2)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("src/tree/ln"), withDestinationURL: root.appendingPathComponent("src/tree/a.bin"))
        let dest = try makeDir("dest"); let log = ProgressLog()
        let r = await engine().run(FileOperation(kind: .copy, sources: [root.appendingPathComponent("src/tree")], destination: dest),
                                   progress: { log.add($0) })
        XCTAssertEqual(r.completedCount, 1)
        XCTAssertEqual(log.all.last?.totalBytes, Int64(5 * 1024 * 1024), "dowiązanie nie liczy się jako rozmiar celu")
        XCTAssertEqual(log.all.last?.bytesDone, Int64(5 * 1024 * 1024))
        XCTAssertEqual((try? FileManager.default.destinationOfSymbolicLink(atPath: dest.appendingPathComponent("tree/ln").path)),
                       root.appendingPathComponent("src/tree/a.bin").path)
    }

    func testCancelInMiddleOfLargeFileCleansUpAndKeepsSource() async throws {
        let f = try bigFile("src/big.bin", mb: 256); let dest = try makeDir("dest")
        let e = engine(); let holder = TaskHolder(); let log = ProgressLog()
        let task = Task { () -> OperationReport in
            await e.run(FileOperation(kind: .copy, sources: [f], destination: dest), progress: { p in
                log.add(p)
                if p.bytesDone > 0 && p.bytesDone < (p.totalBytes ?? 0) { holder.cancel() }
            })
        }
        holder.set(task)
        let r = await task.value
        XCTAssertEqual(r.cancelledCount, 1)
        XCTAssertEqual(names(dest), [], "przerwana kopia nie zostawia ani pliku, ani pliku tymczasowego")
        XCTAssertTrue(exists(f), "źródło nietknięte")
        XCTAssertLessThan(log.all.last?.bytesDone ?? .max, Int64(256 * 1024 * 1024), "kopiowanie faktycznie przerwano w środku")
    }

    func testCancelledCrossVolumeMoveKeepsSource() async throws {
        let f = try bigFile("src/big.bin", mb: 256); let dest = try makeDir("dest")
        let e = FileOperationEngine(trasher: FakeTrasher(bin: bin), forceCrossVolumeMove: true, allowClone: false, progressInterval: 0)
        let holder = TaskHolder()
        let task = Task { () -> OperationReport in
            await e.run(FileOperation(kind: .move, sources: [f], destination: dest), progress: { p in
                if p.bytesDone > 0 && p.bytesDone < (p.totalBytes ?? 0) { holder.cancel() }
            })
        }
        holder.set(task)
        let r = await task.value
        XCTAssertEqual(r.cancelledCount, 1); XCTAssertTrue(exists(f)); XCTAssertEqual(names(dest), [])
    }

    func testDefaultEngineWithCloneStillCopiesCorrectly() async throws {
        let f = try bigFile("src/big.bin", mb: 8); let dest = try makeDir("dest")
        let e = FileOperationEngine(trasher: FakeTrasher(bin: bin))
        let r = await e.run(FileOperation(kind: .copy, sources: [f], destination: dest))
        XCTAssertEqual(r.completedCount, 1)
        XCTAssertEqual(try Data(contentsOf: f), try Data(contentsOf: dest.appendingPathComponent("big.bin")))
    }

    func testFormatting() {
        XCTAssertEqual(ProgressFormat.duration(45), "45 s")
        XCTAssertEqual(ProgressFormat.duration(192), "3 min 12 s")
        XCTAssertEqual(ProgressFormat.duration(3900), "1 h 05 min")
        XCTAssertEqual(ProgressFormat.clock(42), "0:42")
        XCTAssertEqual(ProgressFormat.clock(3669), "1:01:09")
        XCTAssertNil(OperationProgress(completedItems: 0, totalItems: 1, currentItemName: nil, totalBytes: 0).byteFraction)
        XCTAssertEqual(OperationProgress(completedItems: 0, totalItems: 1, currentItemName: nil, bytesDone: 50, totalBytes: 200).byteFraction, 0.25)
    }
}
