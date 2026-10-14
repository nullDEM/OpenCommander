import Foundation
import UniformTypeIdentifiers

/// Listowanie folderu. Nie czyta zawartości plików — tylko metadane.
public enum DirectoryLister {
    static let keys: [URLResourceKey] = [
        .nameKey, .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .isHiddenKey,
        .fileSizeKey, .contentModificationDateKey, .localizedTypeDescriptionKey, .contentTypeKey
    ]

    /// Listuje folder poza głównym wątkiem; reaguje na anulowanie.
    public static func list(_ directory: URL, showHidden: Bool) async throws -> [FileEntry] {
        let task = Task.detached(priority: .userInitiated) {
            try listSync(directory, showHidden: showHidden)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    public static func listSync(_ directory: URL, showHidden: Bool) throws -> [FileEntry] {
        let fm = FileManager.default
        let urls: [URL]
        do {
            urls = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: [])
        } catch {
            throw OperationError.map(error, item: directory.lastPathComponent)
        }
        var result: [FileEntry] = []
        result.reserveCapacity(urls.count)
        for listed in urls {
            try Task.checkCancellation()
            // System potrafi zwrócić ścieżkę z rozwiniętymi dowiązaniami (/var → /private/var).
            // Budujemy URL od podanego folderu, by tożsamość wpisów była spójna z lokalizacją panelu.
            let url = directory.appendingPathComponent(listed.lastPathComponent)
            guard let entry = makeEntry(url, fm: fm) else { continue }
            if !showHidden && entry.isHidden { continue }
            result.append(entry)
        }
        return result
    }

    static func makeEntry(_ url: URL, fm: FileManager) -> FileEntry? {
        guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
        let name = v.name ?? url.lastPathComponent
        let isLink = v.isSymbolicLink ?? false
        var isDir = v.isDirectory ?? false
        if isLink {
            var d: ObjCBool = false
            isDir = fm.fileExists(atPath: url.path, isDirectory: &d) && d.boolValue
        }
        var isPackage = v.isPackage ?? false
        if isLink && isDir {
            // Dowiązanie do programu/pakietu zachowuje się jak pakiet (otwiera się, nie wchodzi do środka).
            isPackage = (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isPackageKey]).isPackage) ?? false
        }
        let kind = isLink ? "Dowiązanie symboliczne" : (v.localizedTypeDescription ?? (isDir ? "Folder" : "Dokument"))
        let size: Int64? = (isDir || isLink) ? nil : v.fileSize.map(Int64.init)
        return FileEntry(
            url: url, name: name, isDirectory: isDir, isSymbolicLink: isLink, isPackage: isPackage,
            isHidden: (v.isHidden ?? false) || name.hasPrefix("."),
            size: size, modificationDate: v.contentModificationDate, kind: kind, contentType: v.contentType
        )
    }
}

public enum FileSorter {
    /// Foldery zawsze przed plikami; remisy rozstrzyga nazwa rosnąco.
    public static func sorted(_ entries: [FileEntry], by key: SortKey, ascending: Bool) -> [FileEntry] {
        entries.sorted { a, b in
            if a.isNavigable != b.isNavigable { return a.isNavigable }
            var result: ComparisonResult
            switch key {
            case .name: result = a.name.localizedStandardCompare(b.name)
            case .size: result = compare(a.sortSize, b.sortSize)
            case .kind: result = a.kind.localizedStandardCompare(b.kind)
            case .date: result = compare(a.sortDate, b.sortDate)
            }
            if result == .orderedSame {
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            if !ascending { result = result == .orderedAscending ? .orderedDescending : .orderedAscending }
            return result == .orderedAscending
        }
    }

    private static func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
    }
}
