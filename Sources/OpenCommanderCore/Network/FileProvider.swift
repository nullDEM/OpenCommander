import Foundation

/// Co dany serwer faktycznie potrafi. Nie zakładamy identycznych możliwości — UI pokazuje tylko to,
/// co jest zaimplementowane i wspierane; resztę zgłasza jako `NetworkError.unsupported`.
public struct ProviderCapabilities: Equatable, Sendable {
    public var list = true
    public var read = true
    public var write = true
    public var makeDirectory = true
    public var rename = true
    /// Przeniesienie w obrębie serwera (nie między serwerami i nie między lokalnym a zdalnym).
    public var move = true
    public var delete = true
    /// Wznawianie przerwanych transferów — **w tej wersji żaden provider tego nie deklaruje**.
    public var resume = false
    public var setMetadata = false
    /// Listowanie zwraca ustrukturyzowane, pewne metadane (FTP: MLSD; LIST jest tylko heurystyką).
    public var reliableMetadata = true

    public init() {}
}

public enum RemoteEntryKind: String, Sendable, Codable { case file, directory, symlink, other }

public struct RemoteEntry: Equatable, Sendable {
    public var name: String
    public var kind: RemoteEntryKind
    public var size: Int64?
    public var modified: Date?
    public var permissions: String?
    /// Dla dowiązania: czy cel jest katalogiem (ustalone przez stat; `nil` = nieznane).
    public var symlinkTargetIsDirectory: Bool?

    public init(name: String, kind: RemoteEntryKind, size: Int64? = nil, modified: Date? = nil,
                permissions: String? = nil, symlinkTargetIsDirectory: Bool? = nil) {
        self.name = name; self.kind = kind; self.size = size; self.modified = modified
        self.permissions = permissions; self.symlinkTargetIsDirectory = symlinkTargetIsDirectory
    }

    public var isDirectory: Bool { kind == .directory }
}

/// Dostawca plików zdalnych. Wszystkie metody są asynchroniczne i poza głównym wątkiem; anulowanie przez `Task.cancel()`
/// (w obsługiwanym zakresie — po anulowaniu provider zgłasza `NetworkError.cancelled`).
public protocol FileProvider: Sendable {
    var capabilities: ProviderCapabilities { get }

    func connect() async throws
    func disconnect() async
    /// Katalog początkowy po zalogowaniu (np. katalog domowy).
    func initialPath() async throws -> RemotePath

    func list(_ path: RemotePath) async throws -> [RemoteEntry]
    /// `nil`, gdy zasób nie istnieje.
    func stat(_ path: RemotePath) async throws -> RemoteEntry?

    /// Pobiera do wskazanego pliku lokalnego (tworzy go; wołający odpowiada za plik tymczasowy i finalny rename).
    func download(_ path: RemotePath, to localFile: URL, progress: @escaping @Sendable (Int64) -> Void) async throws
    /// Wysyła plik lokalny pod `path`. Provider nie może nadpisać istniejącego zasobu, jeśli `overwrite == false`.
    func upload(from localFile: URL, to path: RemotePath, overwrite: Bool, progress: @escaping @Sendable (Int64) -> Void) async throws

    func makeDirectory(_ path: RemotePath) async throws
    func rename(_ from: RemotePath, to: RemotePath) async throws
    /// Usuwa pojedynczy plik albo PUSTY katalog. Rekurencja jest po stronie wołającego (listowanie + usuwanie).
    func delete(_ path: RemotePath, isDirectory: Bool) async throws
}
