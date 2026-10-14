import XCTest
@testable import OpenCommanderCore

@MainActor
final class TabsTests: TempDirTestCase {
    func makeTabs(_ paths: [URL], active: Int = 0) -> PanelTabs {
        PanelTabs(side: .left, settings: paths.map { PanelSettings(path: $0.path) }, activeIndex: active) { s in
            PanelState(side: .left, location: Locations.nearestExistingDirectory(URL(fileURLWithPath: s.path)),
                       sortKey: s.sortKey, sortAscending: s.sortAscending)
        }
    }

    func testAlwaysAtLeastOneTabAndLastCannotBeClosed() async throws {
        let t = makeTabs([])
        XCTAssertEqual(t.tabs.count, 1, "pusta lista → jedna karta domyślna")
        XCTAssertFalse(t.closeTab(at: 0), "ostatniej karty nie zamykamy")
        XCTAssertEqual(t.tabs.count, 1)
    }

    func testEachTabHasIndependentStateAndHistory() async throws {
        let a = try makeDir("a"); let b = try makeDir("b"); try makeFile("a/x.txt"); try makeFile("b/y.txt"); try makeDir("a/sub")
        let t = makeTabs([a, b])
        t.active.reload(); await t.active.waitUntilIdle()
        t.active.selection = [a.appendingPathComponent("x.txt").path]
        t.active.filterText = "x"
        t.active.navigate(to: a.appendingPathComponent("sub")); await t.active.waitUntilIdle()
        t.select(1); await t.active.waitUntilIdle()
        XCTAssertEqual(t.active.location, b.standardizedFileURL)
        XCTAssertEqual(t.active.entries.map(\.name), ["y.txt"])
        XCTAssertTrue(t.active.selection.isEmpty); XCTAssertEqual(t.active.filterText, ""); XCTAssertFalse(t.active.canGoBack)
        t.select(0)
        XCTAssertTrue(t.active.canGoBack, "karta 0 zachowała własną historię")
        XCTAssertEqual(t.active.location, a.appendingPathComponent("sub").standardizedFileURL)
    }

    func testAddTabDuplicatesActiveAndRespectsLimit() async throws {
        let a = try makeDir("a")
        let t = makeTabs([a])
        t.active.setSort(key: .size, ascending: false)
        let n = try XCTUnwrap(t.addTab())
        XCTAssertEqual(n.location, a.standardizedFileURL); XCTAssertEqual(n.sortKey, .size); XCTAssertFalse(n.sortAscending)
        XCTAssertEqual(t.activeIndex, 1, "nowa karta jest aktywna")
        for _ in 0..<20 { t.addTab() }
        XCTAssertEqual(t.tabs.count, PanelTabs.maxTabs)
        XCTAssertNil(t.addTab(), "ponad limit nie dodajemy")
    }

    func testCloseTabKeepsSensibleActive() async throws {
        let ds = try (0..<4).map { try makeDir("d\($0)") }
        let t = makeTabs(ds, active: 2)
        t.closeTab(at: 0)                              // zamknięcie karty przed aktywną
        XCTAssertEqual(t.active.location, ds[2].standardizedFileURL, "aktywna pozostaje ta sama karta")
        t.closeTab(at: t.activeIndex)                  // zamknięcie aktywnej → sąsiednia
        XCTAssertEqual(t.tabs.count, 2)
        XCTAssertTrue(t.tabs.indices.contains(t.activeIndex))
        t.closeTab(at: 99)                             // indeks spoza zakresu nic nie robi
        XCTAssertEqual(t.tabs.count, 2)
    }

    func testNextPreviousWrapAround() async throws {
        let ds = try (0..<3).map { try makeDir("d\($0)") }
        let t = makeTabs(ds)
        t.selectPrevious(); XCTAssertEqual(t.activeIndex, 2)
        t.selectNext(); XCTAssertEqual(t.activeIndex, 0)
    }

    func testMissingFolderFallsBackToExistingAncestor() async throws {
        let a = try makeDir("a")
        let t = makeTabs([a.appendingPathComponent("usunięty/głębiej")])
        XCTAssertEqual(t.active.location, a.standardizedFileURL, "karta z nieistniejącym folderem otwiera najbliższy istniejący")
    }

    func testReplaceAllAndSnapshotRoundTrip() async throws {
        let a = try makeDir("a"); let b = try makeDir("b")
        let t = makeTabs([a])
        t.replaceAll(with: [PanelSettings(path: a.path), PanelSettings(path: b.path, sortKey: .date, sortAscending: false)], activeIndex: 1)
        XCTAssertEqual(t.tabs.count, 2); XCTAssertEqual(t.activeIndex, 1)
        let snap = t.snapshot
        XCTAssertEqual(snap[1].sortKey, .date); XCTAssertFalse(snap[1].sortAscending)
        XCTAssertEqual(snap.map(\.path), [a.standardizedFileURL.path, b.standardizedFileURL.path])
    }

    // MARK: przestrzenie robocze i ustawienia
    func testWorkspaceValidationRejectsEmptyAndDuplicates() {
        let w = Workspace(name: "Praca", left: [], leftActive: 0, right: [], rightActive: 0)
        XCTAssertThrowsError(try Workspaces.validate(name: "  ", in: [w]))
        XCTAssertThrowsError(try Workspaces.validate(name: "praca", in: [w])) { XCTAssertEqual($0 as? OperationError, .nameExists("praca")) }
        XCTAssertNoThrow(try Workspaces.validate(name: "Dom", in: [w]))
    }

    func testSettingsRoundTripWithTabsAndWorkspaces() {
        let suite = UserDefaults(suiteName: "OCT-\(UUID().uuidString)")!
        var s = AppSettings.defaults
        s.leftTabs = [PanelSettings(path: "/a"), PanelSettings(path: "/b", sortKey: .size, sortAscending: false)]; s.leftActiveTab = 1
        s.workspaces = [Workspace(name: "Zdjęcia", left: s.leftTabs, leftActive: 1, right: [PanelSettings(path: "/c")], rightActive: 0, activePanel: .right)]
        let store = SettingsStore(defaults: suite); store.save(s)
        XCTAssertEqual(store.load(), s)
    }

    func testSettingsFromStage2ADecodeWithoutTabs() throws {
        let old = #"{"left":{"path":"/tmp","sortKey":"name","sortAscending":true},"right":{"path":"/tmp","sortKey":"name","sortAscending":true},"favorites":["/x"]}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(old.utf8))
        XCTAssertEqual(s.favorites, ["/x"]); XCTAssertTrue(s.leftTabs.isEmpty); XCTAssertTrue(s.workspaces.isEmpty)
    }
}
