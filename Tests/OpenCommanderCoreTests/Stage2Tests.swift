import XCTest
@testable import OpenCommanderCore

@MainActor
final class Stage2Tests: TempDirTestCase {
    // MARK: filtr
    func testFilterIsCaseAndDiacriticInsensitive() throws {
        for n in ["Żółć.txt", "raport.xlsx", "Raport-2.pdf", "inne.md"] { try makeFile(n) }
        let all = try DirectoryLister.listSync(root, showHidden: false)
        XCTAssertEqual(Set(FileFilter.apply(all, text: "zolc").map(\.name)), ["Żółć.txt"])
        XCTAssertEqual(Set(FileFilter.apply(all, text: "RAPORT").map(\.name)), ["raport.xlsx", "Raport-2.pdf"])
        XCTAssertEqual(FileFilter.apply(all, text: "   ").count, all.count, "pusty filtr nie ukrywa niczego")
        XCTAssertTrue(FileFilter.apply(all, text: "nie-ma-takiego").isEmpty)
    }

    func testFilterNeverLeavesHiddenItemsSelected() async throws {
        try makeFile("a.txt"); try makeFile("b.txt")
        let p = PanelState(side: .left, location: root)
        p.reload(); await p.waitUntilIdle()
        p.selection = Set(p.entries.map(\.id))
        p.filterText = "a.t"
        XCTAssertEqual(p.visibleEntries.map(\.name), ["a.txt"])
        XCTAssertEqual(p.selection, [root.appendingPathComponent("a.txt").path], "operacje nie mogą dotknąć ukrytych filtrem")
        XCTAssertEqual(p.selectedEntries.map(\.name), ["a.txt"])
    }

    func testFilterClearsOnNavigationButSurvivesReload() async throws {
        try makeFile("a.txt"); try makeDir("sub")
        let p = PanelState(side: .left, location: root)
        p.reload(); await p.waitUntilIdle()
        p.filterText = "a"
        p.reload(); await p.waitUntilIdle()
        XCTAssertEqual(p.filterText, "a", "odświeżenie zachowuje filtr")
        p.navigate(to: root.appendingPathComponent("sub")); await p.waitUntilIdle()
        XCTAssertEqual(p.filterText, "", "nowy folder = czysty filtr")
    }

    // MARK: rozmiar folderu
    func testFolderSizeCountsAndIgnoresSymlinkTargets() async throws {
        try makeFile("d/a.bin", String(repeating: "x", count: 1000)); try makeFile("d/sub/b.bin", String(repeating: "y", count: 500))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("d/ln"), withDestinationURL: root.appendingPathComponent("d/a.bin"))
        let r = try await FolderSizer.measure(root.appendingPathComponent("d"))
        XCTAssertEqual(r.bytes, 1500, "dowiązanie nie liczy rozmiaru celu")
        XCTAssertEqual(r.folders, 1); XCTAssertEqual(r.files, 3) // a, b, ln
        XCTAssertEqual(r.unreadable, 0)
    }

    func testFolderSizeReportsUnreadableAndCancels() async throws {
        try makeFile("d/ok.bin", "12345"); let locked = try makeDir("d/locked"); try makeFile("d/locked/x.bin", "999")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        let r = try await FolderSizer.measure(root.appendingPathComponent("d"))
        XCTAssertEqual(r.bytes, 5); XCTAssertGreaterThanOrEqual(r.unreadable, 1, "niepełny wynik jest zgłaszany, nie ukrywany")
        for i in 0..<200 { try makeFile("big/f\(i).txt") }
        let t = Task { try await FolderSizer.measure(self.root.appendingPathComponent("big")) }
        t.cancel()
        do { _ = try await t.value; XCTFail("powinno być anulowane") } catch { XCTAssertTrue(error is CancellationError) }
    }

    // MARK: ulubione / ostatnie / ustawienia
    func testRecentsPromoteDedupeAndLimit() {
        var l: [String] = []
        for p in ["/a", "/b", "/c", "/a"] { l = LocationHistory.promoting(p, in: l, limit: 3) }
        XCTAssertEqual(l, ["/a", "/c", "/b"])
        l = LocationHistory.promoting("/d", in: l, limit: 3)
        XCTAssertEqual(l, ["/d", "/a", "/c"])
    }

    func testOldSettingsStillDecodeWithNewFields() throws {
        let old = #"{"left":{"path":"/tmp","sortKey":"name","sortAscending":true},"right":{"path":"/tmp","sortKey":"size","sortAscending":false},"showHidden":true,"activePanel":"right","operationsExpanded":false}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(old.utf8))
        XCTAssertEqual(s.right.sortKey, .size); XCTAssertTrue(s.showHidden); XCTAssertEqual(s.activePanel, .right)
        XCTAssertEqual(s.favorites, []); XCTAssertEqual(s.recents, []); XCTAssertFalse(s.inspectorVisible)
    }

    func testSettingsRoundTripWithFavorites() {
        let suite = UserDefaults(suiteName: "OCT-\(UUID().uuidString)")!
        var s = AppSettings.defaults; s.favorites = ["/x", "/y"]; s.recents = ["/z"]; s.inspectorVisible = true
        let store = SettingsStore(defaults: suite); store.save(s)
        XCTAssertEqual(store.load(), s)
    }
}
