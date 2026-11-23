import Foundation
import Testing
@testable import OpenCommanderCore

/// Szybka ścieżka listowania (atrybuty z URL zwróconego przez system, opis rodzaju z pamięci podręcznej, podpowiedź
/// `isDirectory`) musi dawać to samo, co odczyt każdego pliku osobno.
final class DirectoryListerFastPathTests {
    let root: URL

    deinit { try? FileManager.default.removeItem(at: root) }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("oc-fastpath-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("Folder"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("Pakiet.app/Contents"), withIntermediateDirectories: true)
        for name in ["a.txt", "b.txt", "obraz.png", "dane.json", "Łódź żółć.md", "bez rozszerzenia", "skrypt.sh"] {
            try Data("x".utf8).write(to: root.appendingPathComponent(name))
        }
        try fm.createSymbolicLink(at: root.appendingPathComponent("link do folderu"), withDestinationURL: root.appendingPathComponent("Folder"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("link do pliku"), withDestinationURL: root.appendingPathComponent("a.txt"))
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("zerwany link").path, withDestinationPath: "/nie/istnieje")
    }

    @Test func fastPathMatchesPerFileReads() throws {
        let fast = try DirectoryLister.listSync(root, showHidden: true)
        #expect(fast.count == 12)
        for entry in fast {
            let classic = try #require(DirectoryLister.makeEntry(root.appendingPathComponent(entry.name), fm: .default))
            #expect(entry.url == classic.url, "URL: \(entry.name)")
            #expect(entry.url.absoluteString == classic.url.absoluteString, "zapis URL: \(entry.name)")
            #expect(entry.isDirectory == classic.isDirectory && entry.isSymbolicLink == classic.isSymbolicLink, "\(entry.name)")
            #expect(entry.isPackage == classic.isPackage, "\(entry.name)")
            let direct = try entry.url.resourceValues(forKeys: [.localizedTypeDescriptionKey]).localizedTypeDescription
            if !entry.isSymbolicLink { #expect(entry.kind == direct, "rodzaj: \(entry.name)") }
        }
    }

    @Test func foldingStillMapsPolishL() {
        #expect(FileFilter.fold("Łódź ŻÓŁĆ") == "lodz zolc")
        #expect(FileFilter.fold("raport 2024") == "raport 2024")
    }
}

struct DuplicateHexTests {
    @Test func hexMatchesFormatSpecifier() {
        let bytes: [UInt8] = Array(0...255)
        #expect(DuplicateFinder.hex(bytes) == bytes.map { String(format: "%02x", $0) }.joined())
        #expect(DuplicateFinder.hex([UInt8]()) == "")
    }
}

struct FileSorterEquivalenceTests {
    /// Wpisy z celowymi remisami (ten sam rozmiar, data, rodzaj), folderami, pakietami, liczbami i polskimi znakami w nazwach.
    static let entries: [FileEntry] = {
        var rng = SystemRandomNumberGenerator()
        let stems = ["Zdjęcie", "raport", "Raport", "żółć", "Łódź", "a", "B", "img", "IMG", "dane", "Ćwiczenie"]
        let kinds = ["Obrazek PNG", "obrazek png", "Dokument PDF", "folder", "Folder", "Plik tekstowy", "dokument tekstowy (zwykły)"]
        let base = Date(timeIntervalSinceReferenceDate: 700_000_000)
        return (0..<3000).map { i in
            let dir = i % 9 == 0
            let name = "\(stems[Int.random(in: 0..<stems.count, using: &rng)]) \(Int.random(in: 0..<400, using: &rng)) (\(i))"
            return FileEntry(url: URL(fileURLWithPath: "/x/\(name)"), name: name, isDirectory: dir, isSymbolicLink: false,
                             isPackage: dir && i % 27 == 0, isHidden: false,
                             size: dir ? nil : Int64(Int.random(in: 0..<50, using: &rng)),
                             modificationDate: i % 13 == 0 ? nil : base.addingTimeInterval(Double(Int.random(in: 0..<20, using: &rng))),
                             kind: kinds[Int.random(in: 0..<kinds.count, using: &rng)], contentType: nil)
        }
    }()

    @Test(arguments: SortKey.allCases, [true, false])
    func fastSortMatchesReference(key: SortKey, ascending: Bool) {
        let fast = FileSorter.sorted(Self.entries, by: key, ascending: ascending).map(\.id)
        let reference = FileSorter.referenceSorted(Self.entries, by: key, ascending: ascending).map(\.id)
        #expect(fast == reference)
    }
}
