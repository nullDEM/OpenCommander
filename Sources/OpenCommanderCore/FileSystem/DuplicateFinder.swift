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
/// Etapy: grupowanie po rozmiarze → skrót początku pliku → pełny SHA-256. Dowiązania i puste pliki są pomijane.
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
        for (size, files) in candidates {
            var byHash: [String: [FileEntryLite]] = [:]
            for f in files {
                try Task.checkCancellation()
                if let h = try? hash(f.url) { byHash[h, default: []].append(f) }
                done += 1
                progress(.init(phase: "Porównywanie zawartości", done: done, total: total))
            }
            for (_, same) in byHash where same.count > 1 {
                let sorted = same.sorted { ($0.modificationDate ?? .distantFuture) < ($1.modificationDate ?? .distantFuture) }
                groups.append(DuplicateGroup(size: size, files: sorted))
            }
        }
        return groups.sorted { $0.wastedBytes > $1.wastedBytes }
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
