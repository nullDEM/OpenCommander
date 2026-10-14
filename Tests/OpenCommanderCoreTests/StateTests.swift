import XCTest
@testable import OpenCommanderCore

@MainActor
final class StateTests: TempDirTestCase {
    // MARK: PanelState

    func testNavigationHistoryAndUp() async throws {
        let a = try makeDir("a"); let b = try makeDir("a/b"); try makeFile("a/b/f.txt")
        let p = PanelState(side: .left, location: root)
        p.reload(); await p.waitUntilIdle()
        p.navigate(to: a); await p.waitUntilIdle()
        p.navigate(to: b); await p.waitUntilIdle()
        XCTAssertEqual(p.entries.map(\.name), ["f.txt"])
        p.goBack(); await p.waitUntilIdle()
        XCTAssertEqual(p.location, a.standardizedFileURL); XCTAssertTrue(p.canGoForward)
        p.goForward(); await p.waitUntilIdle()
        XCTAssertEqual(p.location, b.standardizedFileURL)
        p.goUp(); await p.waitUntilIdle()
        XCTAssertEqual(p.location, a.standardizedFileURL)
        XCTAssertEqual(p.selection, [b.standardizedFileURL.path], "po wyjściu w górę zaznaczony folder, z którego wyszliśmy")
    }

    func testFailedNavigationKeepsLocationAndReportsError() async throws {
        let p = PanelState(side: .left, location: root)
        p.reload(); await p.waitUntilIdle()
        p.navigate(to: root.appendingPathComponent("nie-ma")); await p.waitUntilIdle()
        XCTAssertEqual(p.location, root.standardizedFileURL)
        XCTAssertEqual(p.loadError, .sourceMissing("nie-ma"))
        XCTAssertFalse(p.canGoBack)
        p.reload(); await p.waitUntilIdle()
        XCTAssertNil(p.loadError)
    }

    func testRapidNavigationShowsOnlyLastResult() async throws {
        let dirs = try (0..<20).map { i -> URL in
            let d = try makeDir("d\(i)")
            for j in 0..<30 { try makeFile("d\(i)/f\(i)-\(j).txt") }
            return d
        }
        let p = PanelState(side: .left, location: root)
        for d in dirs { p.navigate(to: d) }
        await p.waitUntilIdle()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(p.location, dirs.last!.standardizedFileURL)
        XCTAssertTrue(p.entries.allSatisfy { $0.name.hasPrefix("f19-") }, "nieaktualne wyniki nie mogą nadpisać ostatniego")
    }

    func testSelectionSurvivesReloadAndDropsMissing() async throws {
        let a = try makeFile("a.txt"); try makeFile("b.txt")
        let p = PanelState(side: .left, location: root)
        p.reload(); await p.waitUntilIdle()
        p.selection = [a.path, root.appendingPathComponent("b.txt").path]
        try FileManager.default.removeItem(at: a)
        p.reload(); await p.waitUntilIdle()
        XCTAssertEqual(p.selection, [root.appendingPathComponent("b.txt").path])
    }

    func testReloadSelectingNewItemAndHiddenToggle() async throws {
        try makeFile(".dot"); try makeFile("x.txt")
        let p = PanelState(side: .left, location: root)
        p.reload(); await p.waitUntilIdle()
        XCTAssertEqual(p.entries.map(\.name), ["x.txt"])
        p.setShowHidden(true); await p.waitUntilIdle()
        XCTAssertEqual(Set(p.entries.map(\.name)), ["x.txt", ".dot"])
        let n = try FileService.createFolder(named: "Nowy", in: root)
        p.reload(selecting: [n]); await p.waitUntilIdle()
        XCTAssertEqual(p.selection, [n.path])
    }

    func testSortChangeAndSummary() async throws {
        try makeFile("a.txt", "1"); try makeFile("b.txt", "123"); try makeDir("dir")
        let p = PanelState(side: .left, location: root)
        p.reload(); await p.waitUntilIdle()
        p.setSort(key: .size, ascending: false)
        XCTAssertEqual(p.entries.map(\.name), ["dir", "b.txt", "a.txt"])
        p.selection = Set(p.entries.map(\.id))
        XCTAssertEqual(p.knownSelectedSize, 4); XCTAssertEqual(p.selectedWithUnknownSize, 1)
    }

    // MARK: OperationCenter

    func testCenterRunsJobAndNotifies() async throws {
        let f = try makeFile("src/a.txt", "A"); let dest = try makeDir("dest")
        let center = OperationCenter(trasher: FakeTrasher(bin: bin))
        var finished: [OperationState] = []
        center.onJobFinished = { finished.append($0.state) }
        center.enqueue(FileOperation(kind: .copy, sources: [f], destination: dest))
        await center.waitUntilIdle()
        XCTAssertEqual(finished, [.completed]); XCTAssertEqual(read(dest.appendingPathComponent("a.txt")), "A")
        XCTAssertEqual(center.jobs.first?.progress.completedItems, 1)
    }

    func testCenterFailedAndPartialStates() async throws {
        let ok = try makeFile("ok.txt"); let dest = try makeDir("dest")
        let center = OperationCenter(trasher: FakeTrasher(bin: bin))
        center.enqueue(FileOperation(kind: .copy, sources: [root.appendingPathComponent("ghost")], destination: dest))
        center.enqueue(FileOperation(kind: .copy, sources: [root.appendingPathComponent("ghost"), ok], destination: dest))
        await center.waitUntilIdle()
        XCTAssertEqual(center.jobs.map(\.state), [.failed, .completedWithIssues])
    }

    func testCenterConflictFlowWaitsForUser() async throws {
        let f = try makeFile("src/a.txt", "NEW"); let dest = try makeDir("dest"); try makeFile("dest/a.txt", "OLD")
        let center = OperationCenter(trasher: FakeTrasher(bin: bin))
        center.enqueue(FileOperation(kind: .copy, sources: [f], destination: dest))
        for _ in 0..<200 where center.pendingConflict == nil { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertNotNil(center.pendingConflict)
        XCTAssertEqual(center.jobs.first?.state, .awaitingDecision)
        XCTAssertEqual(read(dest.appendingPathComponent("a.txt")), "OLD", "bez decyzji nic się nie zmienia")
        center.resolveConflict(ConflictDecision(.keepBoth))
        await center.waitUntilIdle()
        XCTAssertEqual(center.jobs.first?.state, .completed)
        XCTAssertEqual(names(dest), ["a kopia.txt", "a.txt"])
    }

    func testCenterCancelWhileAwaitingDecisionLeavesDataIntact() async throws {
        let f = try makeFile("src/a.txt", "NEW"); let dest = try makeDir("dest"); try makeFile("dest/a.txt", "OLD")
        let g = try makeFile("src/b.txt", "B")
        let center = OperationCenter(trasher: FakeTrasher(bin: bin))
        center.enqueue(FileOperation(kind: .copy, sources: [f, g], destination: dest))
        for _ in 0..<200 where center.pendingConflict == nil { try await Task.sleep(nanoseconds: 5_000_000) }
        center.cancel(center.jobs[0].id)
        await center.waitUntilIdle()
        XCTAssertEqual(center.jobs.first?.state, .cancelled)
        XCTAssertEqual(read(dest.appendingPathComponent("a.txt")), "OLD")
        XCTAssertFalse(exists(dest.appendingPathComponent("b.txt")), "po anulowaniu kolejne elementy nie są kopiowane")
    }

    func testCenterQueuedJobCanBeCancelled() async throws {
        let f = try makeFile("src/a.txt"); let dest = try makeDir("dest"); try makeFile("dest/a.txt")
        let center = OperationCenter(trasher: FakeTrasher(bin: bin))
        center.enqueue(FileOperation(kind: .copy, sources: [f], destination: dest)) // czeka na decyzję
        let second = FileOperation(kind: .trash, sources: [f])
        center.enqueue(second)
        center.cancel(second.id)
        XCTAssertEqual(center.jobs[1].state, .cancelled)
        for _ in 0..<200 where center.pendingConflict == nil { try await Task.sleep(nanoseconds: 5_000_000) }
        center.resolveConflict(ConflictDecision(.skip))
        await center.waitUntilIdle()
        XCTAssertTrue(exists(f), "anulowane zadanie Kosza nie ruszyło pliku")
    }

    // MARK: Ustawienia

    func testSettingsRoundTripAndDefaults() {
        let suite = UserDefaults(suiteName: "OpenCommanderTests-\(UUID().uuidString)")!
        let store = SettingsStore(defaults: suite)
        XCTAssertEqual(store.load(), .defaults)
        var s = AppSettings.defaults
        s.left = PanelSettings(path: "/tmp", sortKey: .date, sortAscending: false)
        s.showHidden = true; s.activePanel = .right
        store.save(s)
        XCTAssertEqual(store.load(), s)
    }

    func testNearestExistingDirectoryFallsBackToAncestor() throws {
        let d = try makeDir("a")
        XCTAssertEqual(Locations.nearestExistingDirectory(d.appendingPathComponent("gone/deeper")), d)
    }
}
