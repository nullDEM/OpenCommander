import Foundation

/// Decyduje o zaufaniu do klucza hosta SSH:
/// znany i zgodny → dalej; nieznany → pytamy użytkownika (zapis dopiero po jawnej akceptacji);
/// zmieniony → **blokada bez pytania** (nigdy nie akceptujemy automatycznie nowego klucza).
public final class HostKeyVerifier: @unchecked Sendable {
    private let store: TrustedHostsStore
    private let prompt: @Sendable (HostKeyInfo) async -> Bool
    private let lock = NSLock()

    public init(store: TrustedHostsStore, prompt: @escaping @Sendable (HostKeyInfo) async -> Bool) {
        self.store = store
        self.prompt = prompt
    }

    public func verify(_ info: HostKeyInfo) async throws {
        var hosts = store.load()
        switch hosts.verdict(for: info) {
        case .trusted:
            return
        case .changed(let expected):
            throw NetworkError.hostKeyChanged(expected: expected, actual: info)
        case .unknown:
            guard await prompt(info) else { throw NetworkError.hostKeyRejected }
            try lock.withLock {
                hosts = store.load()
                hosts.trust(info)
                try store.save(hosts)
            }
        }
    }
}
