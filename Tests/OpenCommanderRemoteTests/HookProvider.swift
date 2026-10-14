import Foundation
@testable import OpenCommanderRemote
@testable import OpenCommanderCore

/// Provider-opakowanie: woła `onUploadBytes` przy każdym kawałku uploadu (deterministyczne wstrzykiwanie awarii/anulowania).
final class HookProvider: FileProvider, @unchecked Sendable {
    let base: any FileProvider; let hook: @Sendable (Int64) -> Void
    init(base: any FileProvider, onUploadBytes: @escaping @Sendable (Int64) -> Void) { self.base = base; self.hook = onUploadBytes }
    var capabilities: ProviderCapabilities { base.capabilities }
    func connect() async throws { try await base.connect() }
    func disconnect() async { await base.disconnect() }
    func initialPath() async throws -> RemotePath { try await base.initialPath() }
    func list(_ p: RemotePath) async throws -> [RemoteEntry] { try await base.list(p) }
    func stat(_ p: RemotePath) async throws -> RemoteEntry? { try await base.stat(p) }
    func download(_ p: RemotePath, to l: URL, progress: @escaping @Sendable (Int64) -> Void) async throws { try await base.download(p, to: l, progress: progress) }
    func upload(from l: URL, to p: RemotePath, overwrite: Bool, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let h = hook
        try await base.upload(from: l, to: p, overwrite: overwrite) { n in h(n); progress(n) }
    }
    func makeDirectory(_ p: RemotePath) async throws { try await base.makeDirectory(p) }
    func rename(_ a: RemotePath, to b: RemotePath) async throws { try await base.rename(a, to: b) }
    func delete(_ p: RemotePath, isDirectory: Bool) async throws { try await base.delete(p, isDirectory: isDirectory) }
}
