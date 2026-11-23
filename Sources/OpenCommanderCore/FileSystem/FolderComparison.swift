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
        // Przechodzenie poziomami: pary podfolderów jednego poziomu są listowane równolegle (listowanie to praca dysku).
        var frontier = [Pair(l: left, r: right, prefix: "")]
        let stop = StopFlag()
        while !frontier.isEmpty {
            let level = try ParallelWork.map(frontier, stop: stop) { pair, stop in try compareOne(pair, stop: stop) }
            var next: [Pair] = []
            for part in level {
                guard let part else { continue }
                result.items += part.items
                result.identical += part.identical
                result.skipped += part.skipped
                next += part.children
            }
            if result.items.count >= itemLimit { result.truncated = true; break }
            frontier = next
        }
        result.items.sort { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
        if result.items.count > itemLimit { result.items.removeLast(result.items.count - itemLimit) }
        return result
    }

    private struct Pair { let l: URL; let r: URL; let prefix: String }
    private struct Partial { var items: [ComparisonItem] = []; var identical = 0; var skipped = 0; var children: [Pair] = [] }

    /// Jedna para folderów (bez schodzenia w głąb — podfoldery wracają jako `children`).
    private static func compareOne(_ p: Pair, stop: StopFlag) throws -> Partial {
        var out = Partial()
        guard let lm = list(p.l), let rm = list(p.r) else { out.skipped = 1; return out }
        for name in Set(lm.keys).union(rm.keys) {
            try stop.check()
            let rel = p.prefix + name
            switch (lm[name], rm[name]) {
            case let (a?, nil):
                out.items.append(.init(relativePath: rel, state: .onlyLeft, isDirectory: a.isDir, leftSize: a.size, rightSize: nil, leftDate: a.date, rightDate: nil))
            case let (nil, b?):
                out.items.append(.init(relativePath: rel, state: .onlyRight, isDirectory: b.isDir, leftSize: nil, rightSize: b.size, leftDate: nil, rightDate: b.date))
            case let (a?, b?):
                if a.isLink || b.isLink { out.skipped += 1; continue }
                if a.isDir && b.isDir {
                    out.children.append(Pair(l: p.l.appendingPathComponent(name, isDirectory: true),
                                             r: p.r.appendingPathComponent(name, isDirectory: true), prefix: rel + "/"))
                } else if a.isDir != b.isDir {
                    out.items.append(.init(relativePath: rel, state: .differs, isDirectory: false, leftSize: a.size, rightSize: b.size, leftDate: a.date, rightDate: b.date))
                } else if a.size == b.size, datesClose(a.date, b.date) {
                    out.identical += 1
                } else {
                    out.items.append(.init(relativePath: rel, state: .differs, isDirectory: false, leftSize: a.size, rightSize: b.size, leftDate: a.date, rightDate: b.date))
                }
            case (nil, nil): break
            }
        }
        return out
    }

    private static func datesClose(_ a: Date?, _ b: Date?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return abs(a.timeIntervalSince(b)) <= dateTolerance
    }
}
