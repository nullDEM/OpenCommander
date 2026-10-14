import XCTest
@testable import OpenCommanderCore

final class ListingTests: TempDirTestCase {
    func testListsFilesAndHidesDotfilesByDefault() throws {
        try makeFile("a.txt"); try makeFile(".hidden"); try makeDir("folder")
        let visible = try DirectoryLister.listSync(root, showHidden: false)
        XCTAssertEqual(Set(visible.map(\.name)), ["a.txt", "folder"])
        let all = try DirectoryLister.listSync(root, showHidden: true)
        XCTAssertEqual(Set(all.map(\.name)), ["a.txt", "folder", ".hidden"])
    }

    func testMetadataAndSymlinks() throws {
        let f = try makeFile("data.bin", "12345")
        let d = try makeDir("dir")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link-dir"), withDestinationURL: d)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link-file"), withDestinationURL: f)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("broken"), withDestinationURL: root.appendingPathComponent("nope"))
        let list = try DirectoryLister.listSync(root, showHidden: true)
        let by = Dictionary(uniqueKeysWithValues: list.map { ($0.name, $0) })
        XCTAssertEqual(by["data.bin"]?.size, 5)
        XCTAssertNil(by["dir"]?.size)
        XCTAssertTrue(by["dir"]!.isNavigable)
        XCTAssertTrue(by["link-dir"]!.isSymbolicLink)
        XCTAssertTrue(by["link-dir"]!.isDirectory)
        XCTAssertTrue(by["link-file"]!.isSymbolicLink)
        XCTAssertFalse(by["link-file"]!.isDirectory)
        XCTAssertTrue(by["broken"]!.isSymbolicLink, "uszkodzone dowiązanie musi być widoczne")
    }

    func testSymlinkToAppBundleBehavesLikePackage() throws {
        let app = try makeDir("Foo.app"); try makeFile("Foo.app/Contents/Info.plist")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Skrot.app"), withDestinationURL: app)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link-do-folderu"), withDestinationURL: try makeDir("zwykly"))
        let by = Dictionary(uniqueKeysWithValues: try DirectoryLister.listSync(root, showHidden: false).map { ($0.name, $0) })
        XCTAssertTrue(by["Foo.app"]!.isPackage)
        XCTAssertTrue(by["Skrot.app"]!.isPackage, "dowiązanie do .app jest pakietem")
        XCTAssertFalse(by["Skrot.app"]!.isNavigable, "dwuklik ma otworzyć program, nie wejść do środka")
        XCTAssertTrue(by["link-do-folderu"]!.isNavigable, "dowiązanie do zwykłego folderu nadal wchodzi do środka")
    }

    func testMissingDirectoryThrowsMappedError() {
        XCTAssertThrowsError(try DirectoryLister.listSync(root.appendingPathComponent("nope"), showHidden: false)) {
            XCTAssertEqual($0 as? OperationError, .sourceMissing("nope"))
        }
    }

    func testSortingFoldersFirstAndNatural() throws {
        try makeFile("file10.txt", "1"); try makeFile("file2.txt", "123"); try makeDir("zdir"); try makeFile("a.md", "12")
        let list = try DirectoryLister.listSync(root, showHidden: false)
        let byName = FileSorter.sorted(list, by: .name, ascending: true).map(\.name)
        XCTAssertEqual(byName, ["zdir", "a.md", "file2.txt", "file10.txt"])
        let nameDesc = FileSorter.sorted(list, by: .name, ascending: false).map(\.name)
        XCTAssertEqual(nameDesc, ["zdir", "file10.txt", "file2.txt", "a.md"])
        let bySize = FileSorter.sorted(list, by: .size, ascending: false).map(\.name)
        XCTAssertEqual(bySize, ["zdir", "file2.txt", "a.md", "file10.txt"])
    }

    func testUnicodeAndEmojiNames() throws {
        try makeFile("zażółć gęślą jaźń.txt"); try makeFile("🎵 muzyka.mp3"); try makeFile("日本語.txt")
        let names = Set(try DirectoryLister.listSync(root, showHidden: false).map(\.name))
        XCTAssertTrue(names.contains("zażółć gęślą jaźń.txt"))
        XCTAssertTrue(names.contains("🎵 muzyka.mp3"))
        XCTAssertTrue(names.contains("日本語.txt"))
    }

    func testPolishPlural() {
        XCTAssertEqual(Polish.items(1), "1 element")
        XCTAssertEqual(Polish.items(3), "3 elementy")
        XCTAssertEqual(Polish.items(5), "5 elementów")
        XCTAssertEqual(Polish.items(12), "12 elementów")
        XCTAssertEqual(Polish.items(22), "22 elementy")
    }
}
