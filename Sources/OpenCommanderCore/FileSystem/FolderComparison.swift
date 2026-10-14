import Foundation

public struct ComparisonItem: Identifiable, Hashable, Sendable {
    public enum State: String, Sendable { case onlyLeft, onlyRight, differs }
    /// Ścieżka względem porównywanych folderów.
    public let relativePath: String
    public let state: State
    public let isDirectory: Bool
    public let leftSize: Int64?
    public let rightSize: Int64?
    public let leftDate: Date?
    public let rightDate: Date?
    public var id: String { relativePath }
}

public struct FolderDiff: Sendable {
    public var items: [ComparisonItem] = []
    public var identical = 0
    /// Elementy nieodczytane lub pominięte (dowiązania, błędy) — wynik jest wtedy niepełny.
    public var skipped = 0
    public var truncated = false
    public init() {}
}

/// Porównanie dwóch drzew po nazwie, rodzaju, rozmiarze i dacie modyfikacji (bez czytania zawartości).
/// Foldery obecne tylko po jednej stronie są raportowane jako jedna pozycja (bez rozwijania).
public enum FolderComparison {
    /// Różnica dat poniżej tego progu jest ignorowana (systemy plików FAT zaokrąglają do 2 s).
    public static let dateTolerance: TimeInterval = 2.5
    public static let itemLimit = 20000

    public static func compare(left: URL, right: URL) async throws -> FolderDiff {
        let task = Task.detached(priority: .userInitiated) { try compareSync(left: left, right: right) }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private struct Node { let isDir: Bool; let isLink: Bool; let size: Int64?; let date: Date? }

    private static func list(_ dir: URL) -> [String: Node]? {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys) else { return nil }
        var map: [String: Node] = [:]
        for u in urls {
            let v = try? u.resourceValues(forKeys: Set(keys))
            let link = v?.isSymbolicLink ?? false
            map[u.lastPathComponent] = Node(isDir: !link && (v?.isDirectory ?? false), isLink: link,
                                            size: v?.fileSize.map(Int64.init), date: v?.contentModificationDate)
        }
        return map
    }

    public static func compareSync(left: URL, right: URL) throws -> FolderDiff {
        var result = FolderDiff()
        try walk(left, right, prefix: "", &result)
        result.items.sort { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
        return result
    }

    private static func walk(_ l: URL, _ r: URL, prefix: String, _ result: inout FolderDiff) throws {
        try Task.checkCancellation()
        guard let lm = list(l), let rm = list(r) else { result.skipped += 1; return }
        for name in Set(lm.keys).union(rm.keys) {
            try Task.checkCancellation()
            if result.items.count >= itemLimit { result.truncated = true; return }
            let rel = prefix + name
            switch (lm[name], rm[name]) {
            case let (a?, nil):
                result.items.append(.init(relativePath: rel, state: .onlyLeft, isDirectory: a.isDir, leftSize: a.size, rightSize: nil, leftDate: a.date, rightDate: nil))
            case let (nil, b?):
                result.items.append(.init(relativePath: rel, state: .onlyRight, isDirectory: b.isDir, leftSize: nil, rightSize: b.size, leftDate: nil, rightDate: b.date))
            case let (a?, b?):
                if a.isLink || b.isLink { result.skipped += 1; continue }
                if a.isDir && b.isDir {
                    try walk(l.appendingPathComponent(name), r.appendingPathComponent(name), prefix: rel + "/", &result)
                } else if a.isDir != b.isDir {
                    result.items.append(.init(relativePath: rel, state: .differs, isDirectory: false, leftSize: a.size, rightSize: b.size, leftDate: a.date, rightDate: b.date))
                } else if a.size == b.size, datesClose(a.date, b.date) {
                    result.identical += 1
                } else {
                    result.items.append(.init(relativePath: rel, state: .differs, isDirectory: false, leftSize: a.size, rightSize: b.size, leftDate: a.date, rightDate: b.date))
                }
            case (nil, nil): break
            }
        }
    }

    private static func datesClose(_ a: Date?, _ b: Date?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return abs(a.timeIntervalSince(b)) <= dateTolerance
    }
}
