import Foundation

/// Wyszukiwanie po nazwie w folderze i wszystkich jego podfolderach. Czyta tylko metadane (nie zawartość plików),
/// nie podąża za dowiązaniami symbolicznymi i nie zagląda do wnętrza pakietów (np. `.app`).
public enum RecursiveSearch {
    public struct Result: Sendable {
        public let entries: [FileEntry]
        /// `true`, gdy znaleziono więcej niż limit — pokazana jest tylko część.
        public let truncated: Bool
    }

    public static let defaultLimit = 5000

    public static func search(root: URL, query: String, showHidden: Bool, limit: Int = defaultLimit) async throws -> Result {
        let task = Task.detached(priority: .userInitiated) {
            try searchSync(root: root, query: query, showHidden: showHidden, limit: limit)
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    public static func searchSync(root: URL, query: String, showHidden: Bool, limit: Int = defaultLimit) throws -> Result {
        let q = FileFilter.fold(query.trimmingCharacters(in: .whitespaces))
        guard !q.isEmpty else { return Result(entries: [], truncated: false) }
        let fm = FileManager.default
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !showHidden { options.insert(.skipsHiddenFiles) }
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.nameKey], options: options,
                                     errorHandler: { _, _ in true }) else {
            return Result(entries: [], truncated: false)
        }
        let rootPath = root.path
        // Enumerator potrafi zwracać ścieżki z rozwiniętymi dowiązaniami (/var → /private/var): bierzemy też prawdziwą ścieżkę.
        let physicalRoot = realpath(rootPath, nil).map { p -> String in defer { free(p) }; return String(cString: p) } ?? rootPath
        var found: [FileEntry] = []
        for case let listed as URL in en {
            try Task.checkCancellation()
            guard FileFilter.fold(listed.lastPathComponent).contains(q) else { continue }
            // Adres budujemy od folderu panelu, by tożsamość wpisów była spójna (/var vs /private/var).
            let p = listed.path
            let rel: String
            if p.hasPrefix(rootPath + "/") { rel = String(p.dropFirst(rootPath.count + 1)) }
            else if p.hasPrefix(physicalRoot + "/") { rel = String(p.dropFirst(physicalRoot.count + 1)) }
            else { continue }
            guard let entry = DirectoryLister.makeEntry(root.appendingPathComponent(rel), fm: fm) else { continue }
            if !showHidden && entry.isHidden { continue }
            if found.count >= limit { return Result(entries: found, truncated: true) }
            found.append(entry)
        }
        return Result(entries: found, truncated: false)
    }
}
