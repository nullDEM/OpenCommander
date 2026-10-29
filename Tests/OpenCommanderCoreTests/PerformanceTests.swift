import XCTest
@testable import OpenCommanderCore

@MainActor
final class PanelPerformanceTests: TempDirTestCase {
    private func makeFiles(_ count: Int, in dir: URL, prefix: String = "plik") throws {
        for i in 0..<count {
            FileManager.default.createFile(atPath: dir.appendingPathComponent(String(format: "\(prefix)-%05d.txt", i)).path, contents: nil)
        }
    }

    func testFoldedNameIsPrecomputedForFilter() {
        let e = FileEntry(url: URL(fileURLWithPath: "/tmp/Żółć.TXT"), name: "Żółć.TXT", isDirectory: false, isSymbolicLink: false,
                          isPackage: false, isHidden: false, size: 1, modificationDate: nil, kind: "x", contentType: nil)
        XCTAssertEqual(e.foldedName, "zolc.txt")
        XCTAssertEqual(FileFilter.apply([e], text: "ZOLC").count, 1)
        XCTAssertTrue(FileFilter.apply([e], text: "inna").isEmpty)
    }

    func testVisibleEntriesFollowFilterAndListChanges() async throws {
        try makeFiles(5, in: root, prefix: "alfa")
        try makeFiles(3, in: root, prefix: "beta")
        let p = PanelState(side: .left, location: root)
        p.reload(); await p.waitUntilIdle()
        XCTAssertEqual(p.visibleEntries.count, 8)
        p.searchSubfolders = false
        p.filterText = "beta"
        XCTAssertEqual(p.visibleEntries.count, 3)
        FileManager.default.createFile(atPath: root.appendingPathComponent("beta-nowy.txt").path, contents: nil)
        p.reload(); await p.waitUntilIdle()
        XCTAssertEqual(p.visibleEntries.count, 4, "lista widocznych odświeża się po zmianie folderu")
        p.filterText = ""
        XCTAssertEqual(p.visibleEntries.count, 9)
    }

    func testReloadWithoutChangesDoesNotNotifyOrReplaceEntries() async throws {
        try makeFiles(4, in: root)
        let p = PanelState(side: .left, location: root)
        var notifications = 0
        p.onStateChange = { notifications += 1 }
        p.reload(); await p.waitUntilIdle()
        let before = p.entries
        XCTAssertEqual(notifications, 0, "odświeżenie tego samego folderu nie zmienia niczego do zapisania")
        p.reload(); await p.waitUntilIdle()
        XCTAssertEqual(p.entries, before)
        XCTAssertEqual(notifications, 0)
        let sub = root.appendingPathComponent("podfolder")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        p.navigate(to: sub); await p.waitUntilIdle()
        XCTAssertEqual(notifications, 1, "zmiana lokalizacji jest zgłaszana")
    }

    func testLargeFolderIsSortedAndResortedInBackground() async throws {
        try makeFiles(PanelState.asyncSortThreshold + 200, in: root)
        let p = PanelState(side: .left, location: root, sortKey: .name, sortAscending: true)
        p.reload(); await p.waitUntilIdle()
        XCTAssertEqual(p.entries.count, PanelState.asyncSortThreshold + 200)
        XCTAssertEqual(p.entries.first?.name, "plik-00000.txt")
        p.setSort(key: .name, ascending: false)
        await p.waitUntilIdle()
        XCTAssertEqual(p.entries.first?.name, String(format: "plik-%05d.txt", PanelState.asyncSortThreshold + 199))
        XCTAssertEqual(p.visibleEntries.first?.name, p.entries.first?.name, "widoczne wpisy też mają nową kolejność")
    }

    func testStaleBackgroundSortDoesNotOverrideNewerOrder() async throws {
        try makeFiles(PanelState.asyncSortThreshold + 50, in: root)
        let p = PanelState(side: .left, location: root)
        p.reload(); await p.waitUntilIdle()
        p.setSort(key: .name, ascending: false)
        p.setSort(key: .name, ascending: true) // drugie zlecenie unieważnia pierwsze
        await p.waitUntilIdle()
        XCTAssertEqual(p.entries.first?.name, "plik-00000.txt")
        XCTAssertEqual(p.sortAscending, true)
    }

    func testSelectionTotalsUseVisibleEntriesOnly() async throws {
        for (name, size) in [("a.txt", 10), ("b.txt", 20), ("c.log", 40)] {
            try Data(count: size).write(to: root.appendingPathComponent(name))
        }
        let p = PanelState(side: .left, location: root)
        p.reload(); await p.waitUntilIdle()
        XCTAssertEqual(p.knownSelectedSize, 0)
        XCTAssertTrue(p.selectedEntries.isEmpty)
        p.selection = Set(p.entries.map(\.id))
        XCTAssertEqual(p.knownSelectedSize, 70)
        p.searchSubfolders = false
        p.filterText = ".txt"
        XCTAssertEqual(p.selection.count, 2, "zaznaczenie przycięte do widocznych")
        XCTAssertEqual(p.knownSelectedSize, 30)
        XCTAssertEqual(p.selectedWithUnknownSize, 0)
    }

    /// Punkt odniesienia (bez progu — tylko pomiar): sortowanie i filtr dużej listy w pamięci.
    func testMeasureSortAndFilterOfLargeList() {
        let entries = (0..<20_000).map { i in
            FileEntry(url: URL(fileURLWithPath: "/tmp/x/plik-\(i).txt"), name: "Plik numer \(i) – zażółć.txt", isDirectory: false,
                      isSymbolicLink: false, isPackage: false, isHidden: false, size: Int64(i), modificationDate: nil, kind: "tekst", contentType: nil)
        }
        measure {
            let sorted = FileSorter.sorted(entries, by: .name, ascending: true)
            XCTAssertEqual(FileFilter.apply(sorted, text: "numer 19999 ").count, 1)
        }
    }
}

final class DuplicateQuickHashTests: TempDirTestCase {
    private func write(_ name: String, head: UInt8 = 1, middle: UInt8, tail: UInt8 = 3, size: Int) throws -> URL {
        var data = Data(repeating: middle, count: size)
        data.replaceSubrange(0..<DuplicateFinder.quickBlock, with: Data(repeating: head, count: DuplicateFinder.quickBlock))
        data.replaceSubrange((size - DuplicateFinder.quickBlock)..<size, with: Data(repeating: tail, count: DuplicateFinder.quickBlock))
        let url = root.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func testFilesDifferingOnlyInTheMiddleAreNotReportedAsDuplicates() throws {
        let size = DuplicateFinder.quickBlock * 4
        _ = try write("a.bin", middle: 7, size: size)
        _ = try write("b.bin", middle: 9, size: size)  // ten sam początek, koniec i rozmiar
        _ = try write("c.bin", middle: 7, size: size)  // identyczny z a.bin
        let groups = try DuplicateFinder.findSync(in: root, showHidden: false)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(Set(groups[0].files.map { $0.url.lastPathComponent }), ["a.bin", "c.bin"])
    }

    func testSmallIdenticalFilesAreGroupedWithoutSecondPass() throws {
        try Data("same content".utf8).write(to: root.appendingPathComponent("x.txt"))
        try Data("same content".utf8).write(to: root.appendingPathComponent("y.txt"))
        try Data("other conten".utf8).write(to: root.appendingPathComponent("z.txt"))
        let groups = try DuplicateFinder.findSync(in: root, showHidden: false)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].files.count, 2)
    }

    func testQuickHashCoversWholeSmallFile() throws {
        let url = root.appendingPathComponent("s.bin")
        try Data(repeating: 5, count: 1000).write(to: url)
        let q = try DuplicateFinder.quickHash(url, size: 1000)
        XCTAssertTrue(q.complete)
        XCTAssertEqual(q.hash, try DuplicateFinder.hash(url))
    }

    func testProgressIsThrottledButFinalStateIsReported() throws {
        for i in 0..<300 { try Data(repeating: UInt8(i % 7), count: 10).write(to: root.appendingPathComponent("f\(i).bin")) }
        let calls = LockedCounter()
        var last: DuplicateFinder.Progress?
        let lock = NSLock()
        _ = try DuplicateFinder.findSync(in: root, showHidden: false) { p in
            calls.increment(); lock.withLock { last = p }
        }
        XCTAssertLessThan(calls.value, 100, "300 plików nie daje 300 zgłoszeń postępu")
        XCTAssertEqual(lock.withLock { last }?.done, lock.withLock { last }?.total, "ostatnie zgłoszenie pokazuje komplet")
    }
}

final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func increment() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}
