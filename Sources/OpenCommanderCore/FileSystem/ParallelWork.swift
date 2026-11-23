import Foundation

/// Flaga przerwania widoczna ze wszystkich wątków roboczych.
final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }

    /// Rzuca `CancellationError`, gdy przerwano — albo zadanie wołającego (tylko na jego wątku), albo inny wątek roboczy.
    func check() throws {
        if Task.isCancelled { set() }
        if isSet { throw CancellationError() }
    }
}

/// Równoległe przetwarzanie niezależnych elementów (odczyty dysku, listowanie folderów) na ograniczonej liczbie wątków.
///
/// Wątek wołający też wykonuje pracę i to on widzi anulowanie swojego `Task` — wtedy ustawia wspólną flagę, którą
/// sprawdzają pozostałe wątki (`StopFlag.check()` w pętlach wewnątrz `body`). Pierwszy błąd przerywa całość.
enum ParallelWork {
    /// Szerokość dla pracy na dysku: SSD dobrze znosi kilka równoległych odczytów; więcej nie przyspiesza.
    static var ioWidth: Int { max(2, min(6, ProcessInfo.processInfo.activeProcessorCount)) }

    /// Wyniki w kolejności wejścia (`nil` — element pominięty przez `body`).
    static func map<T, R>(_ items: [T], width: Int = ioWidth, stop: StopFlag = StopFlag(),
                          _ body: (T, StopFlag) throws -> R?) throws -> [R?] {
        guard !items.isEmpty else { return [] }
        if items.count == 1 || width <= 1 {
            return try items.map { try stop.check(); return try body($0, stop) }
        }
        var results = [R?](repeating: nil, count: items.count)
        let lock = NSLock()
        var next = 0
        var firstError: Error?
        results.withUnsafeMutableBufferPointer { buffer in
            let out = buffer
            DispatchQueue.concurrentPerform(iterations: min(width, items.count)) { _ in
                while true {
                    let index: Int? = lock.withLock {
                        guard firstError == nil, !stop.isSet, next < items.count else { return nil }
                        defer { next += 1 }
                        return next
                    }
                    guard let index else { return }
                    do {
                        try stop.check()
                        out[index] = try body(items[index], stop)   // każdy wątek pisze do innego indeksu
                    } catch {
                        lock.withLock { if firstError == nil { firstError = error } }
                        stop.set()
                        return
                    }
                }
            }
        }
        if let firstError { throw firstError }
        try stop.check()
        return results
    }
}
