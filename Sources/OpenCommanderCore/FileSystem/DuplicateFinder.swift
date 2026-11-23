import Foundation
import CryptoKit

public struct DuplicateGroup: Identifiable, Equatable, Sendable {
    public let size: Int64
    /// Pliki o identycznej zawartości, posortowane od najstarszego.
    public let files: [FileEntryLite]
    public var id: String { files.first?.url.path ?? UUID().uuidString }
    /// Ile miejsca zajmują nadmiarowe kopie.
    public var wastedBytes: Int64 { size * Int64(files.count - 1) }
}

public struct FileEntryLite: Equatable, Hashable, Sendable {
    public let url: URL
    public let modificationDate: Date?
}

/// Szukanie duplikatów po zawartości. Uruchamiane wyłącznie na żądanie użytkownika (czyta zawartość plików).
/// Etapy: grupowanie po rozmiarze → pełny SHA-256 w grupach o tym samym rozmiarze. Dowiązania i puste pliki są pomijane.
public enum DuplicateFinder {
    public struct Progress: Sendable { public var phase: String; public var done: Int; public var total: Int }

    public static func find(in root: URL, showHidden: Bool, minSize: Int64 = 1,
                            progress: @escaping @Sendable (Progress) -> Void = { _ in }) async throws -> [DuplicateGroup] {
        let task = Task.detached(priority: .utility) {
            try findSync(in: root, showHidden: showHidden, minSize: minSize, progress: progress)
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    public static func findSync(in root: URL, showHidden: Bool, minSize: Int64 = 1,
                                progress: @escaping @Sendable (Progress) -> Void = { _ in }) throws -> [DuplicateGroup] {
        // Skanowanie poziomami (foldery jednego poziomu równolegle), z tymi samymi regułami co dotychczasowy enumerator:
        // bez wnętrza pakietów, bez plików ukrytych (chyba że włączone), bez podążania za dowiązaniami.
        let options: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey,
                                      .fileSizeKey, .contentModificationDateKey]
        let scanStop = StopFlag()
        var bySize: [Int64: [FileEntryLite]] = [:]
        var scanned = 0
        var frontier = [root]
        while !frontier.isEmpty {
            let level = try ParallelWork.map(frontier, stop: scanStop) { dir, stop -> (files: [(Int64, FileEntryLite)], dirs: [URL])? in
                guard let urls = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: options) else { return nil }
                var files: [(Int64, FileEntryLite)] = []
                var dirs: [URL] = []
                for url in urls {
                    try stop.check()
                    guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
                    if v.isDirectory == true, v.isSymbolicLink != true {
                        if v.isPackage != true { dirs.append(url) }
                    } else if v.isRegularFile == true, let size = v.fileSize.map(Int64.init), size >= minSize {
                        files.append((size, FileEntryLite(url: url, modificationDate: v.contentModificationDate)))
                    }
                }
                return (files, dirs)
            }
            var next: [URL] = []
            for part in level {
                guard let part else { continue }
                for (size, f) in part.files { bySize[size, default: []].append(f) }
                scanned += part.files.count
                next += part.dirs
            }
            progress(.init(phase: "Skanowanie folderów", done: scanned, total: 0))
            frontier = next
        }
        let candidates = bySize.filter { $0.value.count > 1 }.sorted { $0.key < $1.key }
        let total = candidates.reduce(0) { $0 + $1.value.count }
        let stop = StopFlag()
        let reporter = ThrottledProgress(progress)

        // Krok 1 (równolegle): tani skrót początku i końca pliku. Różne skróty = na pewno różne pliki, bez czytania całości.
        let flat = candidates.flatMap { size, files in files.map { (size: size, file: $0) } }
        let quick = try ParallelWork.map(flat, stop: stop) { item, stop -> (hash: String, complete: Bool)? in
            let q = try? quickHash(item.file.url, size: item.size, stop: stop)
            let done = reporter.advance()
            reporter.emit(.init(phase: "Porównywanie zawartości", done: done, total: total), force: done == total)
            return q
        }

        // Grupy o tym samym rozmiarze i skrócie; kolejność plików w grupie jak przy przeglądaniu folderów.
        var groups: [DuplicateGroup] = []
        var needFull: [(size: Int64, files: [FileEntryLite])] = []
        var offset = 0
        for (size, files) in candidates {
            var byQuick: [String: [FileEntryLite]] = [:]
            var order: [String] = []
            var complete = false
            for (i, f) in files.enumerated() {
                guard let q = quick[offset + i] else { continue }
                if byQuick[q.hash] == nil { order.append(q.hash) }
                byQuick[q.hash, default: []].append(f)
                complete = q.complete
            }
            offset += files.count
            for key in order {
                guard let same = byQuick[key], same.count > 1 else { continue }
                // Plik tak mały, że skrót objął całość — to już pełne porównanie.
                if complete { groups.append(DuplicateGroup(size: size, files: Self.oldestFirst(same))) }
                else { needFull.append((size, same)) }
            }
        }

        // Krok 2 (równolegle): pełny SHA-256 tylko dla plików, które zgadzają się na początku i końcu.
        let fullItems = needFull.flatMap { group in group.files }
        let checked = ThrottledProgress(progress)
        let full = try ParallelWork.map(fullItems, stop: stop) { file, stop -> String? in
            let h = try? hash(file.url, stop: stop)
            checked.emit(.init(phase: "Sprawdzanie pełnej zawartości", done: checked.advance(), total: 0))
            return h
        }
        offset = 0
        for group in needFull {
            var byHash: [String: [FileEntryLite]] = [:]
            var order: [String] = []
            for (i, f) in group.files.enumerated() {
                guard let h = full[offset + i] else { continue }
                if byHash[h] == nil { order.append(h) }
                byHash[h, default: []].append(f)
            }
            offset += group.files.count
            for key in order where (byHash[key]?.count ?? 0) > 1 {
                groups.append(DuplicateGroup(size: group.size, files: Self.oldestFirst(byHash[key]!)))
            }
        }
        try stop.check()
        return groups.sorted { $0.wastedBytes > $1.wastedBytes }
    }

    /// Licznik postępu wspólny dla wątków roboczych; zgłoszenia nie częściej niż co 100 ms
    /// (przy setkach tysięcy plików każde zgłoszenie obciąża interfejs).
    private final class ThrottledProgress: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var lastEmit = 0.0
        private let sink: @Sendable (Progress) -> Void
        init(_ sink: @escaping @Sendable (Progress) -> Void) { self.sink = sink }
        func advance() -> Int { lock.withLock { count += 1; return count } }
        func emit(_ p: Progress, force: Bool = false) {
            let now = ProcessInfo.processInfo.systemUptime
            let send: Bool = lock.withLock {
                guard force || now - lastEmit >= 0.1 else { return false }
                lastEmit = now; return true
            }
            if send { sink(p) }
        }
    }

    private static func oldestFirst(_ files: [FileEntryLite]) -> [FileEntryLite] {
        files.sorted { ($0.modificationDate ?? .distantFuture) < ($1.modificationDate ?? .distantFuture) }
    }

    static let quickBlock = 64 * 1024

    /// Skrót początku i końca pliku (po `quickBlock` bajtów). Dla plików nie większych niż dwa bloki obejmuje całą zawartość
    /// (`complete == true`) i jest wtedy równoważny pełnemu skrótowi.
    static func quickHash(_ url: URL, size: Int64, stop: StopFlag? = nil) throws -> (hash: String, complete: Bool) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        let block = Int64(quickBlock)
        let complete = size <= block * 2
        if complete {
            while let chunk = try handle.read(upToCount: quickBlock), !chunk.isEmpty {
                try Task.checkCancellation(); try stop?.check()
                hasher.update(data: chunk)
            }
        } else {
            if let head = try handle.read(upToCount: quickBlock) { hasher.update(data: head) }
            try handle.seek(toOffset: UInt64(size - block))
            if let tail = try handle.read(upToCount: quickBlock) { hasher.update(data: tail) }
        }
        return (hex(hasher.finalize()), complete)
    }

    private static let hexDigits = Array("0123456789abcdef".utf8)

    /// Skrót jako tekst szesnastkowy (małe litery) — to samo co `String(format: "%02x")` dla każdego bajtu, ale bez
    /// parsowania formatu: przy setkach tysięcy małych plików `String(format:)` zajmował ponad 1/3 czasu wyszukiwania.
    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        var out: [UInt8] = []
        out.reserveCapacity(64)
        for byte in digest {
            out.append(hexDigits[Int(byte >> 4)])
            out.append(hexDigits[Int(byte & 0x0f)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Pełny SHA-256 strumieniowo (bloki 1 MB), z możliwością przerwania.
    static func hash(_ url: URL, stop: StopFlag? = nil) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation(); try stop?.check()
            guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hex(hasher.finalize())
    }
}
