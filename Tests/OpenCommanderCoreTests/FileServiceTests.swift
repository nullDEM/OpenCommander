import XCTest
@testable import OpenCommanderCore

final class FileServiceTests: TempDirTestCase {
    func testCreateFolder() throws {
        let u = try FileService.createFolder(named: "Nowy 📁 folder", in: root)
        XCTAssertTrue(exists(u))
        XCTAssertThrowsError(try FileService.createFolder(named: "Nowy 📁 folder", in: root)) {
            XCTAssertEqual($0 as? OperationError, .nameExists("Nowy 📁 folder"))
        }
    }

    func testInvalidNames() {
        for bad in ["", "   ", "a/b", ".", ".."] {
            XCTAssertThrowsError(try FileService.createFolder(named: bad, in: root), "\(bad)") {
                guard case .invalidName = $0 as? OperationError else { return XCTFail("zły błąd dla \(bad)") }
            }
        }
    }

    func testRename() throws {
        let f = try makeFile("old.txt", "content")
        let new = try FileService.rename(f, to: "nowa nazwa ż.txt")
        XCTAssertFalse(exists(f)); XCTAssertEqual(read(new), "content")
    }

    func testRenameToExistingFails() throws {
        let a = try makeFile("a.txt", "A"); try makeFile("b.txt", "B")
        XCTAssertThrowsError(try FileService.rename(a, to: "b.txt")) {
            XCTAssertEqual($0 as? OperationError, .nameExists("b.txt"))
        }
        XCTAssertEqual(read(a), "A"); XCTAssertEqual(read(root.appendingPathComponent("b.txt")), "B")
    }

    func testRenameMissingSource() {
        XCTAssertThrowsError(try FileService.rename(root.appendingPathComponent("x"), to: "y")) {
            XCTAssertEqual($0 as? OperationError, .sourceMissing("x"))
        }
    }

    /// Zmiana samej wielkości liter — osobny test wymagany w specyfikacji.
    func testCaseOnlyRename() throws {
        let f = try makeFile("report.txt", "data")
        let renamed = try FileService.rename(f, to: "Report.txt")
        XCTAssertEqual(names(root), ["Report.txt"], "nazwa na dysku musi mieć nową wielkość liter")
        XCTAssertEqual(read(renamed), "data")
        XCTAssertTrue(names(root).allSatisfy { !$0.hasPrefix(".opencommander-tmp") }, "bez śmieci tymczasowych")
    }

    func testCaseOnlyRenameOfFolderWithContents() throws {
        try makeFile("docs/inner.txt", "i")
        _ = try FileService.rename(root.appendingPathComponent("docs"), to: "DOCS")
        XCTAssertEqual(names(root), ["DOCS"])
        XCTAssertEqual(read(root.appendingPathComponent("DOCS/inner.txt")), "i")
    }

    func testUnicodeNormalizationRename() throws {
        // NFD → NFC: ta sama nazwa wizualnie; nie może zgubić pliku.
        let nfd = "e\u{0301}.txt", nfc = "\u{00E9}.txt"
        let f = try makeFile(nfd, "u")
        _ = try FileService.rename(f, to: nfc)
        XCTAssertEqual(names(root).count, 1)
        XCTAssertEqual(read(root.appendingPathComponent(nfc)), "u")
    }
}

final class JournalAndBreadcrumbTests: TempDirTestCase {
    var journalFile: URL { root.appendingPathComponent("_journal.json") }
    let prefix = TempJournal.tempPrefix

    func testSweepRemovesLeftoverCopyButNotForeignFiles() throws {
        let tmp = try makeFile("dest/\(prefix)abc", "partial"); let foreign = try makeFile("dest/moje-dane.txt", "ważne")
        let j = TempJournal(fileURL: journalFile)
        j.register(.init(tmp: tmp.path, kind: .copy))
        j.register(.init(tmp: foreign.path, kind: .copy)) // błędny wpis: nazwa bez naszego prefiksu
        let result = TempJournal(fileURL: journalFile).sweep() // nowa instancja = nowa sesja
        XCTAssertEqual(result.removed, 1)
        XCTAssertFalse(exists(tmp)); XCTAssertEqual(read(foreign), "ważne", "cudzych plików nigdy nie ruszamy")
        XCTAssertEqual(TempJournal(fileURL: journalFile).count, 0)
    }

    func testSweepRestoresMovedSourceInsteadOfDeleting() throws {
        let tmp = try makeFile("src/\(prefix)xyz", "DANE UŻYTKOWNIKA")
        TempJournal(fileURL: journalFile).register(.init(tmp: tmp.path, kind: .movedSource, original: root.appendingPathComponent("src/a.txt").path))
        let r = TempJournal(fileURL: journalFile).sweep()
        XCTAssertEqual(r.restored, 1)
        XCTAssertEqual(read(root.appendingPathComponent("src/a.txt")), "DANE UŻYTKOWNIKA"); XCTAssertFalse(exists(tmp))
    }

    func testSweepKeepsMovedSourceWhenOriginalNameTaken() throws {
        let tmp = try makeFile("src/\(prefix)xyz", "A"); let taken = try makeFile("src/a.txt", "B")
        TempJournal(fileURL: journalFile).register(.init(tmp: tmp.path, kind: .movedSource, original: taken.path))
        let r = TempJournal(fileURL: journalFile).sweep()
        XCTAssertEqual(r.leftBehind, [tmp.path])
        XCTAssertEqual(read(tmp), "A", "nic nie zostaje skasowane ani nadpisane"); XCTAssertEqual(read(taken), "B")
    }

    func testEngineLeavesJournalEmptyAndRegistersDuringCopy() async throws {
        let f = try makeFile("src/a.bin", String(repeating: "x", count: 4_000_000)); let dest = try makeDir("dest")
        let j = TempJournal(fileURL: journalFile)
        let e = FileOperationEngine(trasher: FakeTrasher(bin: bin), allowClone: false, progressInterval: 0, journal: j)
        let seen = ProgressLog()
        _ = await e.run(FileOperation(kind: .copy, sources: [f], destination: dest), progress: { p in
            if p.bytesDone > 0 { seen.add(OperationProgress(completedItems: j.count, totalItems: 0, currentItemName: nil)) }
        })
        XCTAssertTrue(seen.all.contains { $0.completedItems == 1 }, "w trakcie kopiowania tymczasowy plik jest w dzienniku")
        XCTAssertEqual(j.count, 0, "po zakończeniu dziennik jest pusty")
        XCTAssertEqual(names(dest), ["a.bin"])
    }

    func testEngineJournalEmptyAfterFailureAndMove() async throws {
        let j = TempJournal(fileURL: journalFile); let dest = try makeDir("dest")
        let e = FileOperationEngine(trasher: FakeTrasher(bin: bin), journal: j)
        let a = try makeFile("src/a.txt")
        _ = await e.run(FileOperation(kind: .move, sources: [a, root.appendingPathComponent("ghost")], destination: dest))
        XCTAssertEqual(j.count, 0)
    }

    func testCaseOnlyRenameLeavesJournalEmpty() throws {
        let j = TempJournal(fileURL: journalFile)
        _ = try FileService.rename(try makeFile("a.txt"), to: "A.txt", journal: j)
        XCTAssertEqual(j.count, 0)
    }

    func testBreadcrumbs() {
        let normal = Breadcrumbs.items(for: URL(fileURLWithPath: "/Users/ola/Dokumenty"), rootName: "Dysk")
        XCTAssertEqual(normal.map(\.title), ["Dysk", "Users", "ola", "Dokumenty"])
        XCTAssertEqual(normal.last?.url.path, "/Users/ola/Dokumenty")
        let ext = Breadcrumbs.items(for: URL(fileURLWithPath: "/Volumes/Zewnętrzny/Zdjęcia/2026"), rootName: "Dysk")
        XCTAssertEqual(ext.map(\.title), ["Zewnętrzny", "Zdjęcia", "2026"])
        XCTAssertEqual(ext.first?.url.path, "/Volumes/Zewnętrzny")
        XCTAssertEqual(Breadcrumbs.items(for: URL(fileURLWithPath: "/"), rootName: "Dysk").map(\.title), ["Dysk"])
    }

    /// Różnica wielkości liter przy kopiowaniu: niezależnie od wrażliwości woluminu nie wolno stracić danych.
    func testCopyWithCaseDifferingNameNeverLosesData() async throws {
        let f = try makeFile("src/Raport.txt", "NOWY"); let dest = try makeDir("dest"); try makeFile("dest/raport.txt", "STARY")
        let e = FileOperationEngine(trasher: FakeTrasher(bin: bin))
        let r = await e.run(FileOperation(kind: .copy, sources: [f], destination: dest),
                            conflictHandler: { _ in ConflictDecision(.keepBoth) })
        XCTAssertTrue(r.failures.isEmpty)
        let contents = names(dest).compactMap { read(dest.appendingPathComponent($0)) }.sorted()
        XCTAssertEqual(contents, ["NOWY", "STARY"], "obie wersje zachowane")
    }

    func testFreeSpaceIsReported() throws {
        XCTAssertNotNil(Locations.freeSpace(at: root))
    }
}
