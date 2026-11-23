import Foundation

/// Filtr bieżącej listy (po nazwie). To NIE jest wyszukiwanie rekurencyjne — działa tylko na już załadowanych wpisach.
public enum FileFilter {
    /// Dopasowanie niewrażliwe na wielkość liter i znaki diakrytyczne („zolc” znajdzie „Żółć”).
    /// „ł” nie ma rozkładu Unicode, więc jest składane do „l” jawnie.
    public static func apply(_ entries: [FileEntry], text: String) -> [FileEntry] {
        let q = fold(text.trimmingCharacters(in: .whitespaces))
        guard !q.isEmpty else { return entries }
        return entries.filter { $0.foldedName.contains(q) }
    }

    static func fold(_ s: String) -> String {
        let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        // Zamiana kosztuje (liczona dla każdego wpisu przy listowaniu) — tylko gdy „ł” faktycznie występuje.
        return folded.contains("ł") ? folded.replacingOccurrences(of: "ł", with: "l") : folded
    }
}

/// Lista ostatnich lokalizacji: najnowsza na początku, bez duplikatów, z limitem.
public enum LocationHistory {
    public static func promoting(_ path: String, in list: [String], limit: Int = 12) -> [String] {
        Array(([path] + list.filter { $0 != path }).prefix(limit))
    }
}

public struct FolderSize: Equatable, Sendable {
    public var bytes: Int64 = 0
    public var files = 0
    public var folders = 0
    /// Elementy, których nie udało się odczytać (brak uprawnień) — wynik jest wtedy niepełny.
    public var unreadable = 0
    public init(bytes: Int64 = 0, files: Int = 0, folders: Int = 0, unreadable: Int = 0) {
        self.bytes = bytes; self.files = files; self.folders = folders; self.unreadable = unreadable
    }
}

/// Rozmiar folderu liczony wyłącznie na żądanie użytkownika; anulowalny; nie podąża za dowiązaniami.
public enum FolderSizer {
    public static func measure(_ url: URL) async throws -> FolderSize {
        let task = Task.detached(priority: .utility) { try measureSync(url) }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    public static func measureSync(_ url: URL) throws -> FolderSize {
        guard FileManager.default.fileExists(atPath: url.path) else { throw OperationError.permissionDenied(url.lastPathComponent) }
        // Poziomami: foldery jednego poziomu listowane równolegle. Jak dotąd: bez podążania za dowiązaniami
        // (dowiązanie liczy się jako plik o rozmiarze 0), z wejściem do pakietów i plików ukrytych.
        var result = FolderSize()
        var frontier = [url]
        let stop = StopFlag()
        while !frontier.isEmpty {
            let level = try ParallelWork.map(frontier, stop: stop) { dir, stop in try measureOne(dir, stop: stop) }
            var next: [URL] = []
            for part in level {
                guard let part else { continue }
                result.bytes += part.size.bytes
                result.files += part.size.files
                result.folders += part.size.folders
                result.unreadable += part.size.unreadable
                next += part.children
            }
            frontier = next
        }
        return result
    }

    private static let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]

    private static func measureOne(_ dir: URL, stop: StopFlag) throws -> (size: FolderSize, children: [URL]) {
        var size = FolderSize()
        var children: [URL] = []
        guard let urls = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: []) else {
            size.unreadable = 1
            return (size, [])
        }
        for u in urls {
            try stop.check()
            guard let v = try? u.resourceValues(forKeys: Set(keys)) else { size.unreadable += 1; continue }
            if v.isDirectory == true && v.isSymbolicLink != true {
                size.folders += 1
                children.append(u)
            } else {
                size.files += 1
                if v.isRegularFile == true { size.bytes += Int64(v.fileSize ?? 0) }
            }
        }
        return (size, children)
    }
}
