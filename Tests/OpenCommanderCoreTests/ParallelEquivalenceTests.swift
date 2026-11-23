import Foundation
import CryptoKit
import Testing
@testable import OpenCommanderCore

/// Równoległe wersje (etap 2 optymalizacji) muszą dawać to samo, co dotychczasowe, sekwencyjne algorytmy —
/// tu odtworzone wprost jako wersje odniesienia.
final class ParallelEquivalenceTests {
    let root: URL
    let left: URL
    let right: URL

    deinit { try? FileManager.default.removeItem(at: root) }

    init() throws {
        let fm = FileManager.default
        root = fm.temporaryDirectory.appendingPathComponent("oc-parallel-\(UUID().uuidString)")
        left = root.appendingPathComponent("L")
        right = root.appendingPathComponent("R")
        // Drzewo: 3 poziomy, pliki o powtarzalnych treściach (duplikaty), pliki ukryte, pakiet, dowiązania.
        for a in 0..<4 {
            for b in 0..<3 {
                let dir = left.appendingPathComponent("A\(a)/B\(b)")
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                for f in 0..<6 {
                    let content = Data("treść \((a + b + f) % 5)".utf8) + Data(repeating: UInt8(f % 3), count: (f % 3) * 70_000)
                    try content.write(to: dir.appendingPathComponent("plik \(f).txt"))
                }
                try Data("ukryty".utf8).write(to: dir.appendingPathComponent(".ukryty"))
            }
        }
        try fm.createDirectory(at: left.appendingPathComponent("Pakiet.app/Contents"), withIntermediateDirectories: true)
        try Data("w pakiecie".utf8).write(to: left.appendingPathComponent("Pakiet.app/Contents/x"))
        try fm.createSymbolicLink(at: left.appendingPathComponent("link do A0"), withDestinationURL: left.appendingPathComponent("A0"))
        try fm.createSymbolicLink(at: left.appendingPathComponent("link do pliku"), withDestinationURL: left.appendingPathComponent("A0/B0/plik 0.txt"))
        try fm.copyItem(at: left, to: right)
        // Różnice po prawej: usunięty plik, zmieniony rozmiar, nowy plik, nowy folder, folder zamiast pliku.
        try fm.removeItem(at: right.appendingPathComponent("A1/B1/plik 2.txt"))
        try Data("inna treść, inny rozmiar".utf8).write(to: right.appendingPathComponent("A2/B0/plik 1.txt"))
        try Data("nowy".utf8).write(to: right.appendingPathComponent("A3/B2/nowy.txt"))
        try fm.createDirectory(at: right.appendingPathComponent("A0/Nowy folder/głęboko"), withIntermediateDirectories: true)
        try fm.removeItem(at: right.appendingPathComponent("A3/B1/plik 4.txt"))
        try fm.createDirectory(at: right.appendingPathComponent("A3/B1/plik 4.txt"), withIntermediateDirectories: true)
    }

    // MARK: Rozmiar folderu

    /// Dotychczasowy algorytm: enumerator bez opcji, dowiązanie liczy się jako plik.
    private func referenceSize(_ url: URL) -> FolderSize {
        var r = FolderSize()
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey, .isDirectoryKey]
        let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in r.unreadable += 1; return true })!
        for case let u as URL in en {
            guard let v = try? u.resourceValues(forKeys: Set(keys)) else { r.unreadable += 1; continue }
            if v.isDirectory == true { r.folders += 1 } else { r.files += 1; if v.isRegularFile == true { r.bytes += Int64(v.fileSize ?? 0) } }
        }
        return r
    }

    @Test func folderSizeMatchesSequentialEnumerator() throws {
        for url in [left, right, root] {
            #expect(try FolderSizer.measureSync(url) == referenceSize(url), "\(url.lastPathComponent)")
        }
    }

    // MARK: Porównanie folderów

    /// Dotychczasowy algorytm: rekurencja w głąb.
    private func referenceCompare(_ l: URL, _ r: URL, prefix: String = "", into out: inout [String: ComparisonItem.State], identical: inout Int, skipped: inout Int) {
        func list(_ d: URL) -> [String: (dir: Bool, link: Bool, size: Int?, date: Date?)]? {
            let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
            guard let urls = try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: keys) else { return nil }
            var m: [String: (Bool, Bool, Int?, Date?)] = [:]
            for u in urls {
                let v = try? u.resourceValues(forKeys: Set(keys)); let link = v?.isSymbolicLink ?? false
                m[u.lastPathComponent] = (!link && (v?.isDirectory ?? false), link, v?.fileSize, v?.contentModificationDate)
            }
            return m
        }
        guard let lm = list(l), let rm = list(r) else { skipped += 1; return }
        for name in Set(lm.keys).union(rm.keys) {
            let rel = prefix + name
            switch (lm[name], rm[name]) {
            case (_?, nil): out[rel] = .onlyLeft
            case (nil, _?): out[rel] = .onlyRight
            case let (a?, b?):
                if a.link || b.link { skipped += 1; continue }
                if a.dir && b.dir { referenceCompare(l.appendingPathComponent(name), r.appendingPathComponent(name), prefix: rel + "/", into: &out, identical: &identical, skipped: &skipped) }
                else if a.dir != b.dir { out[rel] = .differs }
                else if a.size == b.size, abs((a.date ?? .distantPast).timeIntervalSince(b.date ?? .distantPast)) <= FolderComparison.dateTolerance { identical += 1 }
                else { out[rel] = .differs }
            case (nil, nil): break
            }
        }
    }

    @Test func folderComparisonMatchesSequentialWalk() throws {
        var expected: [String: ComparisonItem.State] = [:]
        var identical = 0, skipped = 0
        referenceCompare(left, right, into: &expected, identical: &identical, skipped: &skipped)
        let diff = try FolderComparison.compareSync(left: left, right: right)
        #expect(Dictionary(uniqueKeysWithValues: diff.items.map { ($0.relativePath, $0.state) }) == expected)
        #expect(diff.identical == identical)
        #expect(diff.skipped == skipped)
        #expect(!diff.truncated)
        let paths = diff.items.map(\.relativePath)
        #expect(paths == paths.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        #expect(expected.count >= 5 && identical > 50)
    }

    // MARK: Duplikaty

    @Test func duplicatesMatchBruteForce() throws {
        // Odniesienie: pełny SHA-256 każdego zwykłego, niepustego, nieukrytego pliku poza pakietami.
        var byHash: [String: Set<String>] = [:]
        let en = FileManager.default.enumerator(at: left, includingPropertiesForKeys: [.isRegularFileKey],
                                                options: [.skipsPackageDescendants, .skipsHiddenFiles])!
        for case let u as URL in en {
            guard (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let data = try? Data(contentsOf: u), !data.isEmpty else { continue }
            byHash[SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), default: []].insert(u.standardizedFileURL.path)
        }
        let expected = Set(byHash.values.filter { $0.count > 1 })
        let found = Set(try DuplicateFinder.findSync(in: left, showHidden: false).map { Set($0.files.map { $0.url.standardizedFileURL.path }) })
        #expect(found == expected)
        #expect(expected.count >= 3)
    }
}

struct ParallelWorkTests {
    @Test func keepsInputOrderAndSkips() throws {
        let out = try ParallelWork.map(Array(0..<1000), width: 6) { i, _ in i % 7 == 0 ? nil : i * 2 }
        #expect(out.count == 1000)
        for (i, v) in out.enumerated() { #expect(v == (i % 7 == 0 ? nil : i * 2)) }
    }

    struct Boom: Error {}

    @Test func firstErrorStopsAndPropagates() {
        #expect(throws: Boom.self) {
            _ = try ParallelWork.map(Array(0..<10_000), width: 4) { i, _ -> Int? in
                if i == 50 { throw Boom() }
                return i
            }
        }
    }

    @Test func cancellationOfCallerStopsAllWorkers() async {
        let task = Task.detached {
            try ParallelWork.map(Array(0..<100_000), width: 4) { i, stop -> Int? in
                try stop.check()
                Thread.sleep(forTimeInterval: 0.001)
                return i
            }
        }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
    }
}
