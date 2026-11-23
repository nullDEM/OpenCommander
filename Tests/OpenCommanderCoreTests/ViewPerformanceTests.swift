import Foundation
import Observation
import Testing
@testable import OpenCommanderCore

@MainActor
struct SelectionSummaryTests {
    let dir: TemporaryDirectory

    init() throws {
        dir = try TemporaryDirectory()
    }

    @Test func summaryCountsSizesAndUnknownInOnePass() async throws {
        try dir.makeFile("a.txt", "12345")        // 5 B
        try dir.makeFile("b.txt", "1234567890")   // 10 B
        try dir.makeFile("c.txt", "zzz")          // 3 B (niezaznaczony)
        try dir.makeDirectory("folder")           // rozmiar nieznany
        let panel = PanelState(side: .left, location: dir.root)
        panel.reload()
        await panel.waitUntilIdle()

        #expect(panel.selectionSummary == PanelState.SelectionSummary(), "bez zaznaczenia podsumowanie jest puste")

        let chosen = panel.visibleEntries.filter { ["a.txt", "b.txt", "folder"].contains($0.name) }
        panel.selection = Set(chosen.map(\.id))
        let summary = panel.selectionSummary
        #expect(summary.count == 3)
        #expect(summary.knownSize == 15)
        #expect(summary.withUnknownSize == 1)
        #expect(summary.count == panel.selectedEntries.count)
        #expect(panel.knownSelectedSize == summary.knownSize)
        #expect(panel.selectedWithUnknownSize == summary.withUnknownSize)
    }

    @Test func unchangedReloadDoesNotNotifySelectionObservers() async throws {
        try dir.makeFile("a.txt")
        try dir.makeFile("b.txt")
        let panel = PanelState(side: .left, location: dir.root)
        panel.reload()
        await panel.waitUntilIdle()
        panel.selection = Set(panel.visibleEntries.map(\.id))

        let counter = ChangeCounter()
        withObservationTracking { _ = panel.selection } onChange: { Task { @MainActor in counter.count += 1 } }
        panel.reload()
        await panel.waitUntilIdle()
        try await Task.sleep(for: .milliseconds(50))
        #expect(counter.count == 0, "odświeżenie bez zmian nie powinno unieważniać widoków czytających zaznaczenie")
    }
}

@MainActor
private final class ChangeCounter {
    var count = 0
}

struct BatchRenamePlanCancellationTests {
    @Test func planStopsWhenTaskIsCancelled() async throws {
        let dir = try TemporaryDirectory()
        var entries: [FileEntry] = []
        for i in 0..<600 {
            let url = try dir.makeFile(String(format: "plik-%04d.txt", i))
            entries.append(FileEntry(url: url, name: url.lastPathComponent, isDirectory: false, isSymbolicLink: false, isPackage: false,
                                     isHidden: false, size: 1, modificationDate: nil, kind: "x", contentType: nil))
        }
        var rule = BatchRenameRule()
        rule.prefix = "nowy-"
        let all = BatchRename.plan(entries, rule: rule)
        #expect(all.count == 600, "poza zadaniem plan jest kompletny")

        let task = Task.detached { [entries, rule] () -> [BatchRenameItem] in
            while !Task.isCancelled { await Task.yield() }
            return BatchRename.plan(entries, rule: rule)
        }
        task.cancel()
        let cancelled = await task.value
        #expect(cancelled.isEmpty, "anulowany plan kończy się bez wyniku")
    }
}

struct ProgressFormatTests {
    @Test func bytesFormatterGivesStableDistinctResults() {
        #expect(ProgressFormat.bytes(1_500_000) == ProgressFormat.bytes(1_500_000))
        #expect(ProgressFormat.bytes(1_500_000) != ProgressFormat.bytes(2_500_000))
        #expect(ProgressFormat.bytes(0).isEmpty == false)
    }
}
