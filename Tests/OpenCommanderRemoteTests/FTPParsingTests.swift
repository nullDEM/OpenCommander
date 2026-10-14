import XCTest
@testable import OpenCommanderRemote
@testable import OpenCommanderCore

final class FTPParsingTests: XCTestCase {
    func testMLSDFactsTypesSizesAndNamesWithSpacesAndSemicolons() {
        let text = """
        type=cdir;modify=20251014100000; .\r
        type=pdir;modify=20251014100000; ..\r
        type=file;size=1234;modify=20251014120000.123; raport #1 (100%).txt\r
        type=dir;modify=20251013080000; Mój folder\r
        type=file;size=1;modify=20251014120000; a;b ;c.txt\r
        type=OS.unix=slink:/etc;size=4; link\r
        type=file;size=5;modify=bad; bez-daty.txt\r
        """
        let r = FTPListParser.parseMLSD(text)
        XCTAssertEqual(r.entries.map(\.name), ["raport #1 (100%).txt", "Mój folder", "a;b ;c.txt", "link", "bez-daty.txt"])
        XCTAssertEqual(r.entries[0].size, 1234); XCTAssertEqual(r.entries[0].kind, .file); XCTAssertNotNil(r.entries[0].modified)
        XCTAssertEqual(r.entries[1].kind, .directory); XCTAssertNil(r.entries[1].size)
        XCTAssertEqual(r.entries[3].kind, .symlink)
        XCTAssertNil(r.entries[4].modified)
    }

    func testMLSDRejectsHostileNamesAndMalformedLines() {
        let text = "type=file;size=1; ../../etc/passwd\r\ntype=file;size=1; a/b\r\ntype=file;size=1; ..\r\nśmieci bez faktów\r\ntype=file;size=1; z\u{7}x\r\ntype=file;size=1; dobry.txt\r\n"
        let r = FTPListParser.parseMLSD(text)
        XCTAssertEqual(r.entries.map(\.name), ["dobry.txt"])
        XCTAssertGreaterThanOrEqual(r.skipped, 4)
    }

    func testMLSTTimeIsUTC() throws {
        let d = try XCTUnwrap(FTPListParser.parseMLSTTime("20251014120000"))
        XCTAssertEqual(d.timeIntervalSince1970, 1_760_443_200)
        XCTAssertNil(FTPListParser.parseMLSTTime("2025"))
    }

    func testUnixListFormatWithSymlinksAndSpaces() {
        let now = ISO8601DateFormatter().date(from: "2025-10-14T12:00:00Z")!
        let text = """
        total 12\r
        drwxr-xr-x   2 ftp  ftp      4096 Oct 13 08:00 Mój folder\r
        -rw-r--r--   1 ftp  ftp      1234 Oct 14 11:30 raport #1.txt\r
        lrwxrwxrwx   1 ftp  ftp         4 Mar  1  2024 skrót -> /etc\r
        -rw-r--r--+  1 ftp  ftp         7 Jan 02  2020 stare.txt\r
        drwxr-xr-x   2 ftp  ftp      4096 Oct 13 08:00 .\r
        drwxr-xr-x   2 ftp  ftp      4096 Oct 13 08:00 ..\r
        """
        let r = FTPListParser.parseLIST(text, now: now)
        XCTAssertEqual(r.entries.map(\.name), ["Mój folder", "raport #1.txt", "skrót", "stare.txt"])
        XCTAssertEqual(r.entries[0].kind, .directory)
        XCTAssertEqual(r.entries[1].size, 1234)
        XCTAssertEqual(r.entries[2].kind, .symlink)
        XCTAssertNotNil(r.entries[3].modified)
        XCTAssertEqual(r.skipped, 0)
    }

    func testUnixDateWithoutYearInTheFutureMeansPreviousYear() throws {
        let now = ISO8601DateFormatter().date(from: "2025-01-10T12:00:00Z")!
        let r = FTPListParser.parseLIST("-rw-r--r-- 1 u g 5 Dec 25 10:00 x.txt", now: now)
        let year = Calendar(identifier: .gregorian).component(.year, from: try XCTUnwrap(r.entries.first?.modified))
        XCTAssertEqual(year, 2024)
    }

    func testDOSListFormat() {
        let text = "10-14-25  02:30PM       <DIR>          Mój folder\r\n10-14-25  09:05AM                 1234 plik z spacją.txt\r\n"
        let r = FTPListParser.parseLIST(text)
        XCTAssertEqual(r.entries.map(\.name), ["Mój folder", "plik z spacją.txt"])
        XCTAssertEqual(r.entries[0].kind, .directory); XCTAssertEqual(r.entries[1].size, 1234)
    }

    func testUnknownListFormatIsCountedAsSkippedNotInvented() {
        let r = FTPListParser.parseLIST("jakiś dziwny format serwera\r\nkolejny dziwny wiersz\r\n")
        XCTAssertTrue(r.entries.isEmpty); XCTAssertEqual(r.skipped, 2)
    }

    func testPWDParsing() {
        XCTAssertEqual(FTPProvider.parsePWD("257 \"/home/ola\" is current directory")?.string, "/home/ola")
        XCTAssertEqual(FTPProvider.parsePWD("257 \"/a \"\"b\"\" c\" ok")?.string, "/a \"b\" c")
        XCTAssertNil(FTPProvider.parsePWD("257 brak cudzysłowu"))
    }
}
