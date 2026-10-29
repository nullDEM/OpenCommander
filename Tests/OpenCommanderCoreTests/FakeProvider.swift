import Foundation
@testable import OpenCommanderCore

/// Serwer w pamięci do testów silnika transferów (bez sieci). Umożliwia wstrzykiwanie awarii.
final class FakeProvider: FileProvider, @unchecked Sendable {
    enum Node { case file(Data, Date), dir, symlink(target: String, targetIsDir: Bool) }

    private let lock = NSLock()
    private var tree: [String: Node] = ["/": .dir]
    var capabilities = ProviderCapabilities()
    /// Wstrzykiwanie awarii.
    var failUploadAfterBytes: Int?
    var failUploadWith: Error = NetworkError.connectionLost
    var corruptDownloads = false           // zwraca o 1 bajt mniej niż zadeklarowany rozmiar
    var uploadDelay: TimeInterval = 0
    /// Zwraca true, gdy dany `rename` ma się nie udać (zerwane połączenie).
    var failRename: (@Sendable (RemotePath, RemotePath) -> Bool)?
    var connectDelay: TimeInterval = 0
    /// Połączenie ignoruje anulowanie (jak provider, który kończy `connect` mimo `Task.cancel`).
    var connectSwallowsCancellation = false
    private(set) var disconnectCalls = 0
    var injectedListNames: [String: [RemoteEntry]] = [:]   // path → surowe wpisy (np. złośliwe nazwy)
    private(set) var log: [String] = []

    func seedFile(_ path: String, _ text: String, date: Date = Date()) {
        lock.withLock {
            var p = ""
            for c in RemotePath(parsing: path).parent.components { p += "/" + c; tree[p] = tree[p] ?? .dir }
            tree[RemotePath(parsing: path).string] = .file(Data(text.utf8), date)
        }
    }
    func seedDir(_ path: String) {
        lock.withLock { var p = ""; for c in RemotePath(parsing: path).components { p += "/" + c; tree[p] = tree[p] ?? .dir } }
    }
    func seedSymlink(_ path: String, targetIsDir: Bool) { lock.withLock { tree[RemotePath(parsing: path).string] = .symlink(target: "/x", targetIsDir: targetIsDir) } }
    func contents(_ path: String) -> String? {
        lock.withLock { if case .file(let d, _)? = tree[RemotePath(parsing: path).string] { return String(data: d, encoding: .utf8) } else { return nil } }
    }
    func has(_ path: String) -> Bool { lock.withLock { tree[RemotePath(parsing: path).string] != nil } }
    var allPaths: [String] { lock.withLock { tree.keys.sorted() } }
    var tempLeftovers: [String] { allPaths.filter { $0.contains(".opencommander-tmp-") } }
    var logLines: [String] { lock.withLock { log } }

    func connect() async throws {
        guard connectDelay > 0 else { return }
        if connectSwallowsCancellation { try? await Task.sleep(nanoseconds: UInt64(connectDelay * 1e9)) }
        else { try await Task.sleep(nanoseconds: UInt64(connectDelay * 1e9)) }
    }
    func disconnect() async { lock.withLock { disconnectCalls += 1 } }
    func initialPath() async throws -> RemotePath { .root }

    func list(_ path: RemotePath) async throws -> [RemoteEntry] {
        try lock.withLock {
            log.append("list \(path)")
            if let injected = injectedListNames[path.string] { return injected }
            guard case .dir? = tree[path.string] else { throw NetworkError.notFound(path.string) }
            let prefix = path.isRoot ? "/" : path.string + "/"
            return tree.compactMap { (k, v) -> RemoteEntry? in
                guard k != "/", k.hasPrefix(prefix) else { return nil }
                let rest = String(k.dropFirst(prefix.count)); guard !rest.contains("/") else { return nil }
                return Self.entry(rest, v)
            }
        }
    }

    private static func entry(_ name: String, _ n: Node) -> RemoteEntry {
        switch n {
        case .file(let d, let date): return RemoteEntry(name: name, kind: .file, size: Int64(d.count), modified: date)
        case .dir: return RemoteEntry(name: name, kind: .directory)
        case .symlink(_, let isDir): return RemoteEntry(name: name, kind: .symlink, symlinkTargetIsDirectory: isDir)
        }
    }

    func stat(_ path: RemotePath) async throws -> RemoteEntry? {
        lock.withLock { tree[path.string].map { Self.entry(path.lastComponent ?? "/", $0) } }
    }

    func download(_ path: RemotePath, to localFile: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let data: Data = try lock.withLock {
            log.append("download \(path)")
            guard case .file(let d, _)? = tree[path.string] else { throw NetworkError.notFound(path.string) }
            return d
        }
        try Task.checkCancellation()
        let out = corruptDownloads ? data.dropLast() : data
        try Data(out).write(to: localFile)
        progress(Int64(out.count))
    }

    func upload(from localFile: URL, to path: RemotePath, overwrite: Bool, progress: @escaping @Sendable (Int64) -> Void) async throws {
        lock.withLock { log.append("upload \(path) overwrite=\(overwrite)") }
        if uploadDelay > 0 { try await Task.sleep(nanoseconds: UInt64(uploadDelay * 1e9)) }
        try Task.checkCancellation()
        let data = try Data(contentsOf: localFile)
        try lock.withLock {
            if tree[path.string] != nil && !overwrite { throw NetworkError.conflict(path.string) }
            if let limit = failUploadAfterBytes, data.count > limit {
                tree[path.string] = .file(data.prefix(limit), Date())   // częściowy zapis, jak przy zerwaniu połączenia
                throw failUploadWith
            }
            tree[path.string] = .file(data, Date())
        }
        progress(Int64(data.count))
    }

    func makeDirectory(_ path: RemotePath) async throws {
        try lock.withLock {
            log.append("mkdir \(path)")
            if tree[path.string] != nil { throw NetworkError.conflict(path.string) }
            tree[path.string] = .dir
        }
    }

    func rename(_ from: RemotePath, to: RemotePath) async throws {
        try lock.withLock {
            log.append("rename \(from) → \(to)")
            if failRename?(from, to) == true { throw NetworkError.connectionLost }
            guard let n = tree[from.string] else { throw NetworkError.notFound(from.string) }
            guard tree[to.string] == nil else { throw NetworkError.conflict(to.string) }
            tree[to.string] = n; tree[from.string] = nil
        }
    }

    func delete(_ path: RemotePath, isDirectory: Bool) async throws {
        try lock.withLock {
            log.append("delete \(path)")
            guard tree[path.string] != nil else { throw NetworkError.notFound(path.string) }
            if isDirectory, tree.keys.contains(where: { $0.hasPrefix(path.string + "/") }) { throw NetworkError.conflict("katalog niepusty") }
            tree[path.string] = nil
        }
    }
}
