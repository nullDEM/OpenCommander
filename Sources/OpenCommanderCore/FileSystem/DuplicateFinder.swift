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
                                progress: @Sendable (Progress) -> Void = { _ in }) throws -> [DuplicateGroup] {
        let fm = FileManager.default
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !showHidden { options.insert(.skipsHiddenFiles) }
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: options, errorHandler: { _, _ in true }) else { return [] }

        var bySize: [Int64: [FileEntryLite]] = [:]
        var scanned = 0
        for case let url as URL in en {
            try Task.checkCancellation()
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true,
                  let size = v.fileSize.map(Int64.init), size >= minSize else { continue }
            bySize[size, default: []].append(FileEntryLite(url: url, modificationDate: v.contentModificationDate))
            scanned += 1
            if scanned % 500 == 0 { progress(.init(phase: "Skanowanie folderów", done: scanned, total: 0)) }
        }
        let candidates = bySize.filter { $0.value.count > 1 }
        let total = candidates.values.reduce(0) { $0 + $1.count }
        var done = 0
        var groups: [DuplicateGroup] = []
        var lastEmit = 0.0
        // Postęp nie częściej niż co 100 ms (przy setkach tysięcy plików każde zgłoszenie obciąża interfejs).
        func emit(_ p: Progress, force: Bool = false) {
            let now = ProcessInfo.processInfo.systemUptime
            if force || now - lastEmit >= 0.1 { lastEmit = now; progress(p) }
        }
        var fullChecked = 0
        for (size, files) in candidates {
            // Krok 1: tani skrót początku i końca pliku. Różne skróty = na pewno różne pliki, bez czytania całości.
            var byQuick: [String: [FileEntryLite]] = [:]
            var quickIsComplete = false
            for f in files {
                try Task.checkCancellation()
                if let q = try? quickHash(f.url, size: size) {
                    byQuick[q.hash, default: []].append(f)
                    quickIsComplete = q.complete
                }
                done += 1
                emit(.init(phase: "Porównywanie zawartości", done: done, total: total), force: done == total)
            }
            for (_, same) in byQuick where same.count > 1 {
                if quickIsComplete {
                    // Plik tak mały, że skrót objął całość — to już pełne porównanie.
                    groups.append(DuplicateGroup(size: size, files: Self.oldestFirst(same)))
                    continue
                }
                // Krok 2: pełny SHA-256 tylko dla plików, które zgadzają się na początku i końcu.
                var byHash: [String: [FileEntryLite]] = [:]
                for f in same {
                    try Task.checkCancellation()
                    if let h = try? hash(f.url) { byHash[h, default: []].append(f) }
                    fullChecked += 1
                    emit(.init(phase: "Sprawdzanie pełnej zawartości", done: fullChecked, total: 0))
                }
                for (_, identical) in byHash where identical.count > 1 {
                    groups.append(DuplicateGroup(size: size, files: Self.oldestFirst(identical)))
                }
            }
        }
        return groups.sorted { $0.wastedBytes > $1.wastedBytes }
    }

    private static func oldestFirst(_ files: [FileEntryLite]) -> [FileEntryLite] {
        files.sorted { ($0.modificationDate ?? .distantFuture) < ($1.modificationDate ?? .distantFuture) }
    }

    static let quickBlock = 64 * 1024

    /// Skrót początku i końca pliku (po `quickBlock` bajtów). Dla plików nie większych niż dwa bloki obejmuje całą zawartość
    /// (`complete == true`) i jest wtedy równoważny pełnemu skrótowi.
    static func quickHash(_ url: URL, size: Int64) throws -> (hash: String, complete: Bool) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        let block = Int64(quickBlock)
        let complete = size <= block * 2
        if complete {
            while let chunk = try handle.read(upToCount: quickBlock), !chunk.isEmpty {
                try Task.checkCancellation()
                hasher.update(data: chunk)
            }
        } else {
            if let head = try handle.read(upToCount: quickBlock) { hasher.update(data: head) }
            try handle.seek(toOffset: UInt64(size - block))
            if let tail = try handle.read(upToCount: quickBlock) { hasher.update(data: tail) }
        }
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), complete)
    }

    /// Pełny SHA-256 strumieniowo (bloki 1 MB), z możliwością przerwania.
    static func hash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
