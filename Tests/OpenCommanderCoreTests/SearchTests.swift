import XCTest
@testable import OpenCommanderCore

final class RecursiveSearchTests: TempDirTestCase {
    private func touch(_ rel: String) throws {
        let u = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: u)
    }

    func testFindsFilesInNestedFoldersIgnoringCaseAndDiacritics() throws {
        try touch("Muzyka/Rock/Żółć.mp3"); try touch("Muzyka/Pop/inne.mp3"); try touch("zolc-top.txt")
        let r = try RecursiveSearch.searchSync(root: root, query: "ZOLC", showHidden: false)
        XCTAssertEqual(Set(r.entries.map(\.name)), ["Żółć.mp3", "zolc-top.txt"])
        XCTAssertEqual(r.entries.first { $0.name == "Żółć.mp3" }?.url.path, root.appendingPathComponent("Muzyka/Rock/Żółć.mp3").path)
    }

    func testMatchesFolderNamesAndSkipsHiddenUnlessAsked() throws {
        try touch("a/piosenki/x.txt"); try touch(".ukryty/piosenka.mp3")
        XCTAssertEqual(try RecursiveSearch.searchSync(root: root, query: "piosen", showHidden: false).entries.map(\.name), ["piosenki"])
        XCTAssertEqual(try RecursiveSearch.searchSync(root: root, query: "piosen", showHidden: true).entries.count, 2)
    }

    func testDoesNotFollowSymlinkedFolders() throws {
        try touch("real/cel.txt")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: root.appendingPathComponent("real"))
        let r = try RecursiveSearch.searchSync(root: root, query: "cel", showHidden: false)
        XCTAssertEqual(r.entries.count, 1)
    }

    func testLimitTruncates() throws {
        for i in 0..<10 { try touch("f\(i).txt") }
        let r = try RecursiveSearch.searchSync(root: root, query: "f", showHidden: false, limit: 4)
        XCTAssertEqual(r.entries.count, 4); XCTAssertTrue(r.truncated)
    }

    @MainActor func testPanelSearchesSubfoldersAndClearsOnNavigate() async throws {
        try touch("Album/utwor-1.mp3")
        let panel = PanelState(side: .left, location: root)
        panel.reload(); await panel.waitUntilIdle()
        panel.filterText = "utwor"
        XCTAssertTrue(panel.visibleEntries.isEmpty || panel.isSearching)
        for _ in 0..<40 where panel.visibleEntries.isEmpty { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertEqual(panel.visibleEntries.map(\.name), ["utwor-1.mp3"])
        panel.searchSubfolders = false
        XCTAssertTrue(panel.visibleEntries.isEmpty)
    }
}
