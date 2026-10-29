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
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "ł", with: "l")
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
        var result = FolderSize()
        var unreadable = 0
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey, .isDirectoryKey]
        guard let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [],
                                                      errorHandler: { _, _ in unreadable += 1; return true }) else {
            throw OperationError.permissionDenied(url.lastPathComponent)
        }
        for case let u as URL in en {
            try Task.checkCancellation()
            guard let v = try? u.resourceValues(forKeys: Set(keys)) else { unreadable += 1; continue }
            if v.isDirectory == true { result.folders += 1 }
            else { result.files += 1; if v.isRegularFile == true { result.bytes += Int64(v.fileSize ?? 0) } }
        }
        result.unreadable = unreadable
        return result
    }
}
