import Foundation

/// Wzajemne wykluczanie dla operacji asynchronicznych (FIFO). Jedna sesja biblioteki SFTP obsługuje w danej chwili
/// jedno żądanie — nie zakładamy bezpiecznej równoległości; kolejne żądania (listowanie, kolejne kawałki transferu) czekają w kolejce.
actor AsyncMutex {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        await acquire()
        defer { release() }
        return try await body()
    }

    private func acquire() async {
        if !locked { locked = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty { locked = false } else { waiters.removeFirst().resume() }
    }
}
