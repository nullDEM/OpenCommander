import Foundation
import UniformTypeIdentifiers

/// Pojedynczy element listingu. Tożsamość = ścieżka (nie indeks w tabeli).
public struct FileEntry: Identifiable, Hashable, Sendable {
    public let url: URL
    public let name: String
    /// Katalog lub dowiązanie do katalogu (pakiety `.app` również są katalogami).
    public let isDirectory: Bool
    public let isSymbolicLink: Bool
    public let isPackage: Bool
    public let isHidden: Bool
    /// `nil` dla katalogów i dowiązań (rozmiary folderów nie są liczone automatycznie).
    public let size: Int64?
    public let modificationDate: Date?
    public let kind: String
    public let contentType: UTType?

    /// Lokalnie: ścieżka. Zdalnie: pełny adres `ocremote://…` (ta sama ścieżka na dwóch serwerach to dwa różne elementy).
    public var id: String { url.isFileURL ? url.path : url.absoluteString }

    /// Czy dwuklik wchodzi do środka (a nie otwiera w aplikacji).
    public var isNavigable: Bool { isDirectory && !isPackage }

    // Klucze sortowania dla kolumn tabeli.
    public var sortSize: Int64 { size ?? -1 }
    public var sortDate: Date { modificationDate ?? .distantPast }

    public init(url: URL, name: String, isDirectory: Bool, isSymbolicLink: Bool, isPackage: Bool,
                isHidden: Bool, size: Int64?, modificationDate: Date?, kind: String, contentType: UTType?) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.isSymbolicLink = isSymbolicLink
        self.isPackage = isPackage
        self.isHidden = isHidden
        self.size = size
        self.modificationDate = modificationDate
        self.kind = kind
        self.contentType = contentType
    }
}

public enum PanelSide: String, Codable, Sendable, CaseIterable {
    case left, right
    public var other: PanelSide { self == .left ? .right : .left }
}

public enum SortKey: String, Codable, CaseIterable, Sendable {
    case name, size, kind, date
}
