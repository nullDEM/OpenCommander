import XCTest
@testable import OpenCommanderCore

final class Stage3Tests: TempDirTestCase {
    private func write(_ rel: String, _ text: String, date: Date? = nil) throws {
        let u = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: u)
        if let date { try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: u.path) }
    }
    private func entries(_ names: [String]) -> [FileEntry] {
        names.compactMap { DirectoryLister.makeEntry(root.appendingPathComponent($0), fm: .default) }
    }

    // MARK: Zmiana nazw
    func testReplaceCaseNumberingKeepsExtension() throws {
        try write("a_stare.mp3", "1"); try write("b_stare.mp3", "2")
        var rule = BatchRenameRule()
        rule.find = "_stare"; rule.replaceWith = ""; rule.numberPosition = .prefix; rule.numberDigits = 3
        let plan = BatchRename.plan(entries(["a_stare.mp3", "b_stare.mp3"]), rule: rule)
        XCTAssertEqual(plan.map(\.newName), ["001 a.mp3", "002 b.mp3"])
        XCTAssertTrue(plan.allSatisfy { $0.status == .ok })
    }

    func testDuplicateTargetsAndExistingTargetsAreProblems() throws {
        try write("a.txt", "1"); try write("b.txt", "2"); try write("zajete.txt", "3")
        var rule = BatchRenameRule(); rule.find = "a"; rule.replaceWith = "x"
        // a.txt → x.txt ; b.txt bez zmian
        var plan = BatchRename.plan(entries(["a.txt", "b.txt"]), rule: rule)
        XCTAssertEqual(plan[0].status, .ok); XCTAssertEqual(plan[1].status, .unchanged)
        // dwa elementy → ta sama nazwa
        var same = BatchRenameRule(); same.find = "a"; same.replaceWith = "b"
        plan = BatchRename.plan(entries(["a.txt", "b.txt"]), rule: same)
        if case .problem = plan[0].status {} else { XCTFail("kolizja w obrębie zestawu: \(plan[0].status)") }
        // cel istnieje na dysku
        var onDisk = BatchRenameRule(); onDisk.find = "a"; onDisk.replaceWith = "zajete.txt"; onDisk.caseMode = .none
        try write("a", "4")
        plan = BatchRename.plan(entries(["a"]), rule: onDisk)
        XCTAssertEqual(plan.first?.newName, "zajete.txt")
        if case .problem = plan[0].status {} else { XCTFail("cel istnieje na dysku, powinien być problem: \(plan[0].status)") }
    }

    func testApplyRenamesOnlyOkItemsAndNeverOverwrites() throws {
        try write("a.txt", "A"); try write("b.txt", "B"); try write("c.txt", "C")
        var rule = BatchRenameRule(); rule.prefix = "n-"
        try write("n-b.txt", "ISTNIEJE")
        let plan = BatchRename.plan(entries(["a.txt", "b.txt", "c.txt"]), rule: rule)
        XCTAssertEqual(plan.map { $0.status == .ok }, [true, false, true])
        let out = BatchRename.apply(plan)
        XCTAssertEqual(out.renamed, 2)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("n-b.txt")), "ISTNIEJE")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("b.txt").path))
    }

    func testCaseModes() throws {
        try write("ala ma KOTA.txt", "1")
        var r = BatchRenameRule(); r.caseMode = .words
        XCTAssertEqual(BatchRename.plan(entries(["ala ma KOTA.txt"]), rule: r)[0].newName, "Ala Ma Kota.txt")
        r.caseMode = .upper
        XCTAssertEqual(BatchRename.plan(entries(["ala ma KOTA.txt"]), rule: r)[0].newName, "ALA MA KOTA.txt")
    }

    // MARK: Porównanie
    func testComparisonFindsOnlyLeftOnlyRightAndDifferences() throws {
        let past = Date(timeIntervalSinceNow: -10_000)
        try write("L/same.txt", "x", date: past); try write("R/same.txt", "x", date: past)
        try write("L/tylko-l.txt", "1"); try write("R/tylko-p.txt", "2")
        try write("L/sub/zmieniony.txt", "aaa", date: past); try write("R/sub/zmieniony.txt", "aaaa", date: past)
        try write("L/nowyfolder/f.txt", "1")
        let r = try FolderComparison.compareSync(left: root.appendingPathComponent("L"), right: root.appendingPathComponent("R"))
        let map = Dictionary(uniqueKeysWithValues: r.items.map { ($0.relativePath, $0.state) })
        XCTAssertEqual(map["tylko-l.txt"], .onlyLeft)
        XCTAssertEqual(map["tylko-p.txt"], .onlyRight)
        XCTAssertEqual(map["sub/zmieniony.txt"], .differs)
        XCTAssertEqual(map["nowyfolder"], .onlyLeft)
        XCTAssertNil(map["nowyfolder/f.txt"], "folder tylko po jednej stronie nie jest rozwijany")
        XCTAssertEqual(r.identical, 1)
    }

    // MARK: Duplikaty
    func testDuplicatesByContentNotJustSize() throws {
        let old = Date(timeIntervalSinceNow: -5000)
        try write("a/p.txt", "ta sama tresc", date: old); try write("b/q.txt", "ta sama tresc")
        try write("c/r.txt", "inna tresc!!!") // ta sama długość (13), inna zawartość
        try write("pusty1", ""); try write("pusty2", "")
        let g = try DuplicateFinder.findSync(in: root, showHidden: false)
        XCTAssertEqual(g.count, 1)
        XCTAssertEqual(g[0].files.map { $0.url.lastPathComponent }, ["p.txt", "q.txt"], "najstarszy pierwszy")
        XCTAssertEqual(g[0].wastedBytes, 13)
    }
}
