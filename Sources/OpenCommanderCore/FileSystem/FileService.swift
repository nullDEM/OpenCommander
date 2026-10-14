import Foundation

/// Proste, synchroniczne operacje na pojedynczych elementach (nowy folder, zmiana nazwy).
/// Wywołuj poza głównym wątkiem.
public enum FileService {
    public static func validate(name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw OperationError.invalidName("nazwa nie może być pusta.") }
        if name.contains("/") || name.contains("\0") { throw OperationError.invalidName("nazwa nie może zawierać znaku „/”.") }
        if name == "." || name == ".." { throw OperationError.invalidName("zarezerwowana nazwa.") }
        if name.utf8.count > 255 { throw OperationError.invalidName("nazwa jest za długa.") }
    }

    @discardableResult
    public static func createFolder(named name: String, in parent: URL) throws -> URL {
        try validate(name: name)
        let url = parent.appendingPathComponent(name, isDirectory: true)
        if exists(url) { throw OperationError.nameExists(name) }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        } catch {
            throw OperationError.map(error, item: name)
        }
        return url
    }

    /// Zmienia nazwę. Zmiana samej wielkości liter działa też na wolumenach
    /// niewrażliwych na wielkość liter (przez nazwę tymczasową).
    @discardableResult
    public static func rename(_ url: URL, to newName: String, journal: TempJournal? = nil) throws -> URL {
        try validate(name: newName)
        let fm = FileManager.default
        let oldName = url.lastPathComponent
        if newName == oldName { return url }
        guard exists(url) else { throw OperationError.sourceMissing(oldName) }
        let target = url.deletingLastPathComponent().appendingPathComponent(newName)

        if exists(target) {
            guard foldedEqual(oldName, newName), isSameFile(url, target) else {
                throw OperationError.nameExists(newName)
            }
            // Ten sam plik, inna wielkość liter (lub normalizacja Unicode).
            let tmp = url.deletingLastPathComponent().appendingPathComponent("\(TempJournal.tempPrefix)\(UUID().uuidString)")
            journal?.register(.init(tmp: tmp.path, kind: .movedSource, original: url.path))
            defer { journal?.unregister(tmpPath: tmp.path) }
            do {
                try fm.moveItem(at: url, to: tmp)
            } catch { throw OperationError.map(error, item: oldName) }
            do {
                try fm.moveItem(at: tmp, to: target)
            } catch {
                try? fm.moveItem(at: tmp, to: url) // wycofanie
                throw OperationError.map(error, item: oldName)
            }
            return target
        }
        do {
            try fm.moveItem(at: url, to: target)
        } catch { throw OperationError.map(error, item: oldName) }
        return target
    }

    static func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    static func foldedEqual(_ a: String, _ b: String) -> Bool {
        a.precomposedStringWithCanonicalMapping.lowercased() == b.precomposedStringWithCanonicalMapping.lowercased()
    }

    static func isSameFile(_ a: URL, _ b: URL) -> Bool {
        let ka = try? a.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        let kb = try? b.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        guard let x = ka as? NSObject, let y = kb as? NSObject else { return false }
        return x.isEqual(y)
    }
}

public struct VolumeInfo: Identifiable, Hashable, Sendable {
    public let url: URL
    public let name: String
    public let isInternal: Bool
    /// System zgłasza wolumin jako wysuwalny lub wymienny (dysk USB, karta, obraz dysku).
    public let isEjectable: Bool
    public var id: String { url.path }

    public init(url: URL, name: String, isInternal: Bool, isEjectable: Bool = false) {
        self.url = url; self.name = name; self.isInternal = isInternal; self.isEjectable = isEjectable
    }

    /// Dysk systemowy i woluminy systemowe nigdy nie są wysuwalne z poziomu aplikacji.
    public var canEject: Bool {
        isEjectable && url.path != "/" && !url.path.hasPrefix("/System/")
    }
}

public enum Locations {
    public static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    public static func standard() -> [(String, String, URL)] {
        let fm = FileManager.default
        var list: [(String, String, URL)] = [("Katalog domowy", "house", home)]
        let dirs: [(String, String, FileManager.SearchPathDirectory)] = [
            ("Pulpit", "menubar.dock.rectangle", .desktopDirectory),
            ("Dokumenty", "doc", .documentDirectory),
            ("Pobrane", "arrow.down.circle", .downloadsDirectory),
            ("Programy", "square.grid.2x2", .applicationDirectory)
        ]
        for (title, icon, dir) in dirs {
            if let url = fm.urls(for: dir, in: dir == .applicationDirectory ? .localDomainMask : .userDomainMask).first {
                list.append((title, icon, url))
            }
        }
        return list
    }

    public static func mountedVolumes() -> [VolumeInfo] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsInternalKey, .volumeIsEjectableKey, .volumeIsRemovableKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.map { url in
            let v = try? url.resourceValues(forKeys: Set(keys))
            return VolumeInfo(url: url, name: v?.volumeName ?? url.lastPathComponent, isInternal: v?.volumeIsInternal ?? true,
                              isEjectable: (v?.volumeIsEjectable ?? false) || (v?.volumeIsRemovable ?? false))
        }
    }

    public static func rootVolumeName() -> String {
        (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? "Macintosh HD"
    }

    /// Wolne miejsce na woluminie zawierającym `url` (dla użytkownika, nie dla „purgeable”).
    public static func freeSpace(at url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    /// Najbliższy istniejący folder (sam `url` lub najbliższy przodek), w ostateczności katalog domowy.
    public static func nearestExistingDirectory(_ url: URL) -> URL {
        var current = url
        while true {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: current.path, isDirectory: &isDir), isDir.boolValue { return current }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { return home }
            current = parent
        }
    }
}

public struct Breadcrumb: Identifiable, Equatable, Sendable {
    public let title: String
    public let url: URL
    public var id: String { url.isFileURL ? url.path : url.absoluteString }
    public init(title: String, url: URL) { self.title = title; self.url = url }
}

public enum Breadcrumbs {
    /// Okruszki ścieżki. Dla `/Volumes/Nazwa/...` korzeniem jest wolumin „Nazwa”, nie dysk systemowy.
    public static func items(for url: URL, rootName: String = Locations.rootVolumeName()) -> [Breadcrumb] {
        let comps = url.standardizedFileURL.pathComponents
        var current = URL(fileURLWithPath: "/")
        var result: [Breadcrumb] = []
        var rest = comps.dropFirst()
        if comps.count >= 3, comps[1] == "Volumes" {
            current = current.appendingPathComponent("Volumes").appendingPathComponent(comps[2])
            result.append(Breadcrumb(title: comps[2], url: current))
            rest = comps.dropFirst(3)
        } else {
            result.append(Breadcrumb(title: rootName, url: current))
        }
        for part in rest {
            current = current.appendingPathComponent(part)
            result.append(Breadcrumb(title: part, url: current))
        }
        return result
    }
}
