import Foundation
import UniformTypeIdentifiers
import os

/// Listowanie folderu. Nie czyta zawartości plików — tylko metadane.
public enum DirectoryLister {
    /// Atrybuty pobierane hurtem przy listowaniu. Bez `localizedTypeDescriptionKey`: to zapytanie do LaunchServices
    /// (~45 µs na plik), a opis zależy wyłącznie od typu — liczymy go raz na typ (`kindDescription`).
    static let keys: [URLResourceKey] = [
        .nameKey, .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .isHiddenKey,
        .fileSizeKey, .contentModificationDateKey, .contentTypeKey
    ]
    private static let keySet = Set(keys)

    /// Opis rodzaju („Obrazek PNG”) według identyfikatora typu. Zmiana języka systemu i tak wymaga ponownego uruchomienia.
    private static let kindCache = OSAllocatedUnfairLock(initialState: [String: String]())

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
            // Tożsamość wpisu budujemy od podanego folderu (spójna z lokalizacją panelu), ale atrybuty czytamy z URL
            // zwróconego przez system: tylko on ma je już pobrane hurtem — nowy URL czytałby każdy plik z dysku ponownie.
            // Podpowiedź `isDirectory` z wyniku listowania: bez niej `appendingPathComponent` robi dodatkowy `lstat` na plik.
            let url = directory.appendingPathComponent(listed.lastPathComponent, isDirectory: listed.hasDirectoryPath)
            guard let entry = makeEntry(url, source: listed, fm: fm) else { continue }
            if !showHidden && entry.isHidden { continue }
            result.append(entry)
        }
        return result
    }

    static func makeEntry(_ url: URL, fm: FileManager) -> FileEntry? {
        makeEntry(url, source: url, fm: fm)
    }

    /// `url` — tożsamość wpisu; `source` — ten sam plik, z którego czytamy atrybuty (może mieć je już w pamięci podręcznej).
    static func makeEntry(_ url: URL, source: URL, fm: FileManager) -> FileEntry? {
        guard let v = try? source.resourceValues(forKeys: keySet) else { return nil }
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
        let kind = isLink ? "Dowiązanie symboliczne" : (kindDescription(source, type: v.contentType) ?? (isDir ? "Folder" : "Dokument"))
        let size: Int64? = (isDir || isLink) ? nil : v.fileSize.map(Int64.init)
        return FileEntry(
            url: url, name: name, isDirectory: isDir, isSymbolicLink: isLink, isPackage: isPackage,
            isHidden: (v.isHidden ?? false) || name.hasPrefix("."),
            size: size, modificationDate: v.contentModificationDate, kind: kind, contentType: v.contentType
        )
    }

    /// Opis rodzaju z pamięci podręcznej; przy pierwszym pliku danego typu — zapytanie do systemu.
    static func kindDescription(_ url: URL, type: UTType?) -> String? {
        if let id = type?.identifier, let cached = kindCache.withLock({ $0[id] }) { return cached }
        let description = try? url.resourceValues(forKeys: [.localizedTypeDescriptionKey]).localizedTypeDescription
        if let id = type?.identifier, let description { kindCache.withLock { $0[id] = description } }
        return description
    }
}

public enum FileSorter {
    /// Foldery zawsze przed plikami; remisy rozstrzyga nazwa rosnąco.
    ///
    /// Klucze są liczone raz na wpis, a sortowane są indeksy: porównanie nie kopiuje całych `FileEntry`, nie mostkuje
    /// nazwy do `NSString` przy każdym wywołaniu, a rodzaj (kilkadziesiąt różnych wartości) porównuje jako liczbę.
    /// Kolejność jest identyczna z porównywaniem wpisów wprost (`referenceSorted`, sprawdzane w testach).
    public static func sorted(_ entries: [FileEntry], by key: SortKey, ascending: Bool) -> [FileEntry] {
        let n = entries.count
        guard n > 1 else { return entries }
        var nav = [Bool](); nav.reserveCapacity(n)
        var names = [NSString](); names.reserveCapacity(n)
        for e in entries { nav.append(e.isNavigable); names.append(e.name as NSString) }
        var ints = [Int64]()
        var doubles = [Double]()
        switch key {
        case .name: break
        case .size: ints = entries.map(\.sortSize)
        case .date: doubles = entries.map { $0.sortDate.timeIntervalSinceReferenceDate }
        case .kind: ints = kindRanks(entries.map(\.kind))
        }
        func byName(_ a: Int, _ b: Int) -> ComparisonResult { names[a].localizedStandardCompare(names[b] as String) }
        let order = (0..<n).sorted { a, b in
            if nav[a] != nav[b] { return nav[a] }
            var result: ComparisonResult
            switch key {
            case .name: result = byName(a, b)
            case .size, .kind: result = compare(ints[a], ints[b])
            case .date: result = compare(doubles[a], doubles[b])
            }
            if result == .orderedSame { return byName(a, b) == .orderedAscending }
            if !ascending { result = result == .orderedAscending ? .orderedDescending : .orderedAscending }
            return result == .orderedAscending
        }
        return order.map { entries[$0] }
    }

    /// Rangi rodzajów: równe w sensie `localizedStandardCompare` dostają tę samą rangę.
    static func kindRanks(_ kinds: [String]) -> [Int64] {
        let distinct = Array(Set(kinds)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        var rank: [String: Int64] = [:]
        var current: Int64 = 0
        for (i, k) in distinct.enumerated() {
            if i > 0, distinct[i - 1].localizedStandardCompare(k) != .orderedSame { current += 1 }
            rank[k] = current
        }
        return kinds.map { rank[$0] ?? 0 }
    }

    /// Wersja odniesienia (porównanie wpisów wprost) — używana w testach do sprawdzenia, że szybka daje tę samą kolejność.
    static func referenceSorted(_ entries: [FileEntry], by key: SortKey, ascending: Bool) -> [FileEntry] {
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
