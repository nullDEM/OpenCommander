import Foundation

/// Dziennik plików tymczasowych aplikacji. Pozwala po awarii lub zamknięciu w trakcie operacji
/// posprzątać wyłącznie własne pliki — i odzyskać dane, które chwilowo leżały pod nazwą tymczasową.
public final class TempJournal: @unchecked Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable {
            /// Niepełna kopia — można usunąć.
            case copy
            /// Oryginał przeniesiony pod nazwę tymczasową (rename) — NIE wolno usuwać, trzeba przywrócić.
            case movedSource
        }
        public var tmp: String
        public var kind: Kind
        public var original: String?
        public init(tmp: String, kind: Kind, original: String? = nil) {
            self.tmp = tmp; self.kind = kind; self.original = original
        }
    }

    public struct SweepResult: Equatable, Sendable {
        public var removed = 0
        public var restored = 0
        /// Pliki, których nie wolno było ani usunąć, ani przywrócić — zostają dla użytkownika.
        public var leftBehind: [String] = []
        public var isEmpty: Bool { removed == 0 && restored == 0 && leftBehind.isEmpty }
    }

    public static let tempPrefix = ".opencommander-tmp-"

    private let fileURL: URL
    private let lock = NSLock()
    private var entries: [String: Entry]

    public init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let list = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = Dictionary(list.map { ($0.tmp, $0) }, uniquingKeysWith: { a, _ in a })
        } else {
            entries = [:]
        }
    }

    public static var `default`: TempJournal {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        // Folder wg identyfikatora pakietu: instancje o innym identyfikatorze (np. testowa kopia) nie współdzielą dziennika.
        let id = Bundle.main.bundleIdentifier ?? "OpenCommander"
        let dir = base.appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return TempJournal(fileURL: dir.appendingPathComponent("temp-journal.json"))
    }

    public var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }

    public func register(_ entry: Entry) {
        lock.lock(); defer { lock.unlock() }
        entries[entry.tmp] = entry
        save()
    }

    public func unregister(tmpPath: String) {
        lock.lock(); defer { lock.unlock() }
        if entries.removeValue(forKey: tmpPath) != nil { save() }
    }

    /// Sprząta po poprzedniej sesji. Wywołuj przy starcie, zanim ruszy jakakolwiek operacja.
    public func sweep() -> SweepResult {
        lock.lock(); defer { lock.unlock() }
        var result = SweepResult()
        let fm = FileManager.default
        for entry in entries.values {
            let tmp = URL(fileURLWithPath: entry.tmp)
            // Twarda zasada: dotykamy wyłącznie plików o naszej nazwie tymczasowej.
            guard tmp.lastPathComponent.hasPrefix(Self.tempPrefix),
                  (try? fm.attributesOfItem(atPath: tmp.path)) != nil else { continue }
            switch entry.kind {
            case .copy:
                if (try? fm.removeItem(at: tmp)) != nil { result.removed += 1 } else { result.leftBehind.append(entry.tmp) }
            case .movedSource:
                guard let original = entry.original else { result.leftBehind.append(entry.tmp); continue }
                let originalURL = URL(fileURLWithPath: original)
                if (try? fm.attributesOfItem(atPath: originalURL.path)) == nil,
                   (try? fm.moveItem(at: tmp, to: originalURL)) != nil {
                    result.restored += 1
                } else {
                    result.leftBehind.append(entry.tmp)
                }
            }
        }
        entries.removeAll()
        save()
        return result
    }

    private func save() {
        if let data = try? JSONEncoder().encode(Array(entries.values)) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
