import Foundation

/// Zasady zbiorczej zmiany nazw. Kolejność: zamiana tekstu → wielkość liter → prefiks/sufiks → numeracja.
/// Rozszerzenie plików jest zachowane; dla folderów reguły dotyczą całej nazwy.
public struct BatchRenameRule: Equatable, Sendable {
    public enum CaseMode: String, CaseIterable, Sendable { case none, lower, upper, words }
    public enum NumberPosition: String, CaseIterable, Sendable { case none, prefix, suffix }

    public var find = ""
    public var replaceWith = ""
    public var caseSensitive = false
    public var caseMode: CaseMode = .none
    public var prefix = ""
    public var suffix = ""
    public var numberPosition: NumberPosition = .none
    public var numberStart = 1
    public var numberStep = 1
    public var numberDigits = 2

    public init() {}
}

public struct BatchRenameItem: Identifiable, Equatable, Sendable {
    public enum Status: Equatable, Sendable { case ok, unchanged, problem(String) }
    public let source: URL
    public let oldName: String
    public let newName: String
    public let status: Status
    public var id: String { source.path }
}

public enum BatchRename {
    /// Buduje podgląd: dla każdego elementu nowa nazwa i ewentualny problem. Nic nie dotyka dysku poza sprawdzeniem istnienia.
    public static func plan(_ entries: [FileEntry], rule: BatchRenameRule) -> [BatchRenameItem] {
        let proposed: [(FileEntry, String)] = entries.enumerated().map { index, e in
            (e, newName(for: e, index: index, rule: rule))
        }
        let currentNames = Set(entries.map { FileFilter.fold($0.name) + "|" + $0.url.deletingLastPathComponent().path })
        var seen: [String: Int] = [:]
        for (e, n) in proposed where n != e.name {
            seen[FileFilter.fold(n) + "|" + e.url.deletingLastPathComponent().path, default: 0] += 1
        }
        return proposed.map { e, name in
            if name == e.name { return BatchRenameItem(source: e.url, oldName: e.name, newName: name, status: .unchanged) }
            if let problem = problem(for: e, newName: name, seen: seen, currentNames: currentNames) {
                return BatchRenameItem(source: e.url, oldName: e.name, newName: name, status: .problem(problem))
            }
            return BatchRenameItem(source: e.url, oldName: e.name, newName: name, status: .ok)
        }
    }

    public static func newName(for entry: FileEntry, index: Int, rule: BatchRenameRule) -> String {
        let ns = entry.name as NSString
        let hasExt = !entry.isDirectory && !ns.pathExtension.isEmpty && ns.deletingPathExtension != ""
        var base = hasExt ? ns.deletingPathExtension : entry.name
        let ext = hasExt ? ns.pathExtension : ""

        if !rule.find.isEmpty {
            base = base.replacingOccurrences(of: rule.find, with: rule.replaceWith,
                                             options: rule.caseSensitive ? [] : [.caseInsensitive])
        }
        switch rule.caseMode {
        case .none: break
        case .lower: base = base.lowercased()
        case .upper: base = base.uppercased()
        case .words: base = base.capitalized
        }
        base = rule.prefix + base + rule.suffix
        if rule.numberPosition != .none {
            let n = rule.numberStart + index * rule.numberStep
            let digits = String(format: "%0\(max(1, rule.numberDigits))d", n)
            base = rule.numberPosition == .prefix ? digits + " " + base : base + " " + digits
        }
        return ext.isEmpty ? base : base + "." + ext
    }

    private static func problem(for e: FileEntry, newName: String, seen: [String: Int], currentNames: Set<String>) -> String? {
        do { try FileService.validate(name: newName) } catch { return error.localizedDescription }
        let dir = e.url.deletingLastPathComponent()
        let key = FileFilter.fold(newName) + "|" + dir.path
        if (seen[key] ?? 0) > 1 { return "kilka elementów dostałoby tę samą nazwę" }
        // Cel zajęty przez inny zaznaczony element (zamiana/łańcuch) — odrzucamy, by niczego nie nadpisać.
        if currentNames.contains(key), !FileService.foldedEqual(e.name, newName) { return "nazwa zajęta przez inny zaznaczony element" }
        let target = dir.appendingPathComponent(newName)
        if FileService.exists(target), !(FileService.foldedEqual(e.name, newName) && FileService.isSameFile(e.url, target)) {
            return "element o tej nazwie już istnieje"
        }
        return nil
    }

    public struct Outcome: Sendable {
        public var renamed = 0
        public var failures: [String] = []
        public var newURLs: [URL] = []
    }

    /// Wykonuje tylko pozycje o statusie `.ok`; błąd jednej nie zatrzymuje pozostałych (raportowany jest na końcu).
    public static func apply(_ items: [BatchRenameItem], journal: TempJournal? = nil) -> Outcome {
        var out = Outcome()
        for item in items where item.status == .ok {
            do {
                let url = try FileService.rename(item.source, to: item.newName, journal: journal)
                out.renamed += 1; out.newURLs.append(url)
            } catch {
                out.failures.append("„\(item.oldName)”: \(error.localizedDescription)")
            }
        }
        return out
    }
}
