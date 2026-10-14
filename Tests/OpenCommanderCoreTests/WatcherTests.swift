import XCTest
@testable import OpenCommanderCore

@MainActor
final class WatcherTests: TempDirTestCase {
    func testPanelRefreshesAfterExternalChange() async throws {
        let panel = PanelState(side: .left, location: root)
        panel.reload()
        await panel.waitUntilIdle()
        XCTAssertTrue(panel.entries.isEmpty)

        try Data("x".utf8).write(to: root.appendingPathComponent("nowy.txt"))
        for _ in 0..<40 where panel.entries.isEmpty { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertEqual(panel.entries.map(\.name), ["nowy.txt"])

        try FileManager.default.removeItem(at: root.appendingPathComponent("nowy.txt"))
        for _ in 0..<40 where !panel.entries.isEmpty { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertTrue(panel.entries.isEmpty)
    }

    func testWatcherOnMissingFolderIsNil() {
        XCTAssertNil(DirectoryWatcher(url: root.appendingPathComponent("brak")) {})
    }
}

final class DropPlannerTests: TempDirTestCase {
    func testSameVolumeMovesAndOptionCopies() throws {
        let a = root.appendingPathComponent("a.txt"); try Data("x".utf8).write(to: a)
        let dest = root.appendingPathComponent("d"); try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        XCTAssertEqual(DropPlanner.kind(sources: [a], destination: dest, optionHeld: false), .move)
        XCTAssertEqual(DropPlanner.kind(sources: [a], destination: dest, optionHeld: true), .copy)
    }

    func testItemsAlreadyInDestinationAreDropped() {
        let a = root.appendingPathComponent("a.txt"), b = root.appendingPathComponent("d/b.txt")
        XCTAssertEqual(DropPlanner.effectiveSources([a, b], destination: root.appendingPathComponent("d")), [a])
        XCTAssertEqual(DropPlanner.effectiveSources([root], destination: root), [])
    }
}
