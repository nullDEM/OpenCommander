import Foundation

public enum OperationKind: String, Sendable {
    case copy, move, trash
    /// Trwałe usunięcie NA SERWERZE (bez Kosza, zwykle nieodwracalne). Dotyczy wyłącznie zasobów zdalnych.
    case delete
}

public struct FileOperation: Identifiable, Sendable {
    public let id: UUID
    public let kind: OperationKind
    public let sources: [URL]
    /// Folder docelowy (dla kopiowania i przenoszenia).
    public let destination: URL?

    public init(kind: OperationKind, sources: [URL], destination: URL? = nil) {
        self.id = UUID()
        self.kind = kind
        self.sources = sources
        self.destination = destination
    }

    /// Czy operacja dotyczy zasobów zdalnych (źródło lub cel ma adres `ocremote://`).
    public var involvesRemote: Bool { sources.contains(where: \.isRemoteLocation) || (destination?.isRemoteLocation ?? false) }

    public var title: String {
        let n = Polish.items(sources.count)
        let dest = destination?.lastPathComponent ?? ""
        switch kind {
        case .copy: return "Kopiowanie: \(n) → „\(dest)”"
        case .move: return "Przenoszenie: \(n) → „\(dest)”"
        case .trash: return "Przenoszenie do Kosza: \(n)"
        case .delete: return "Usuwanie na serwerze: \(n)"
        }
    }
}

public enum OperationState: Equatable, Sendable {
    case queued, running, awaitingDecision, completed, completedWithIssues, failed, cancelled

    public var isFinished: Bool {
        switch self {
        case .completed, .completedWithIssues, .failed, .cancelled: return true
        default: return false
        }
    }
}

public enum ConflictResolution: String, Sendable {
    case skip, keepBoth, replace
}

public struct ConflictDecision: Sendable {
    public var resolution: ConflictResolution
    public var applyToAll: Bool
    public init(_ resolution: ConflictResolution, applyToAll: Bool = false) {
        self.resolution = resolution
        self.applyToAll = applyToAll
    }
}

public struct Conflict: Sendable, Equatable {
    public let source: URL
    public let existing: URL
}

public enum ItemOutcome: Equatable, Sendable {
    case completed(URL?)
    case skipped(String)
    case failed(OperationError)
    case cancelled
}

public struct ItemResult: Equatable, Sendable {
    public let source: URL
    public let outcome: ItemOutcome
}

public struct OperationReport: Equatable, Sendable {
    public let results: [ItemResult]
    public init(results: [ItemResult]) { self.results = results }

    public var completedCount: Int { results.filter { if case .completed = $0.outcome { true } else { false } }.count }
    public var skippedCount: Int { results.filter { if case .skipped = $0.outcome { true } else { false } }.count }
    public var cancelledCount: Int { results.filter { $0.outcome == .cancelled }.count }
    public var failures: [(URL, OperationError)] {
        results.compactMap { if case .failed(let e) = $0.outcome { ($0.source, e) } else { nil } }
    }

    public var summary: String {
        var parts = ["wykonano: \(completedCount)"]
        if skippedCount > 0 { parts.append("pominięto: \(skippedCount)") }
        if !failures.isEmpty { parts.append("błędy: \(failures.count)") }
        if cancelledCount > 0 { parts.append("anulowano: \(cancelledCount)") }
        return parts.joined(separator: ", ")
    }
}

/// Postęp operacji. Bajty są liczone tylko tam, gdzie są rzeczywiście mierzone
/// (kopiowanie danych); `totalBytes == nil` oznacza postęp wyłącznie w elementach.
public struct OperationProgress: Equatable, Sendable {
    public var completedItems: Int
    public var totalItems: Int
    public var currentItemName: String?
    public var bytesDone: Int64
    public var totalBytes: Int64?

    public init(completedItems: Int, totalItems: Int, currentItemName: String?,
                bytesDone: Int64 = 0, totalBytes: Int64? = nil) {
        self.completedItems = completedItems
        self.totalItems = totalItems
        self.currentItemName = currentItemName
        self.bytesDone = bytesDone
        self.totalBytes = totalBytes
    }

    /// Ułamek 0…1 tylko gdy znamy rozmiar w bajtach; inaczej `nil` (UI pokazuje postęp elementów).
    public var byteFraction: Double? {
        guard let total = totalBytes, total > 0 else { return nil }
        return min(1, Double(bytesDone) / Double(total))
    }
}

public enum ProgressFormat {
    /// Rozmiar w jednostkach dziesiętnych jak w Finderze, ale „0 B” zamiast „zero KB”.
    public static func bytes(_ n: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f.string(fromByteCount: n)
    }

    /// „45 s”, „3 min 12 s”, „1 h 05 min”.
    public static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s < 60 { return "\(s) s" }
        if s < 3600 { return "\(s / 60) min \(String(format: "%02d", s % 60)) s" }
        return "\(s / 3600) h \(String(format: "%02d", (s % 3600) / 60)) min"
    }

    /// Czas zegarowy „0:42”, „1:05:09”.
    public static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 3600 { return "\(s / 60):\(String(format: "%02d", s % 60))" }
        return "\(s / 3600):\(String(format: "%02d", (s % 3600) / 60)):\(String(format: "%02d", s % 60))"
    }
}

public enum Polish {
    /// „1 element”, „3 elementy”, „5 elementów”.
    public static func items(_ n: Int) -> String {
        let mod10 = n % 10, mod100 = n % 100
        if n == 1 { return "1 element" }
        if (2...4).contains(mod10) && !(12...14).contains(mod100) { return "\(n) elementy" }
        return "\(n) elementów"
    }
}
