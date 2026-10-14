import Foundation

/// Obserwuje jeden folder i zgłasza (z opóźnieniem łączącym serię zdarzeń), że jego zawartość się zmieniła.
/// Obejmuje dodanie, usunięcie i zmianę nazwy elementów w tym folderze; zmiany *wewnątrz* podfolderów
/// i samej zawartości plików nie są zgłaszane. Nie czyta żadnych plików.
public final class DirectoryWatcher: @unchecked Sendable {
    private let source: DispatchSourceFileSystemObject
    private let queue = DispatchQueue(label: "opencommander.watcher")
    private var pending: DispatchWorkItem?
    private let debounce: TimeInterval
    private let handler: @Sendable () -> Void

    /// Zwraca `nil`, gdy folderu nie da się obserwować (brak uprawnień, nie istnieje).
    public init?(url: URL, debounce: TimeInterval = 0.3, onChange: @escaping @Sendable () -> Void) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        self.debounce = debounce
        self.handler = onChange
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename, .extend], queue: queue)
        source.setEventHandler { [weak self] in self?.schedule() }
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    private func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [handler] in handler() }
        pending = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    public func stop() {
        queue.async { [self] in pending?.cancel(); pending = nil }
        source.cancel()
    }

    deinit { source.cancel() }
}
