import Foundation
import Network

/// Prosty przekaźnik TCP na 127.0.0.1 do testów zerwania połączenia: `dropAll()` twardo zamyka wszystkie połączenia
/// (jak zerwane łącze), czego serwer Citadel sam nie umie (zamyka tylko nasłuch).
final class TCPProxy: @unchecked Sendable {
    private let listener: NWListener
    private let target: UInt16
    private let queue = DispatchQueue(label: "oc.test.tcpproxy")
    private var pairs: [(NWConnection, NWConnection)] = []
    private(set) var port: Int = 0

    init(targetPort: Int) async throws {
        target = UInt16(targetPort)
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] inbound in self?.accept(inbound) }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let once = NSLock(); var done = false
            listener.stateUpdateHandler = { state in
                once.lock(); defer { once.unlock() }
                guard !done else { return }
                switch state {
                case .ready: done = true; c.resume()
                case .failed(let e): done = true; c.resume(throwing: e)
                default: break
                }
            }
            listener.start(queue: queue)
        }
        port = Int(listener.port?.rawValue ?? 0)
    }

    private func accept(_ inbound: NWConnection) {
        let outbound = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: target)!, using: .tcp)
        pairs.append((inbound, outbound))
        pipe(inbound, outbound); pipe(outbound, inbound)
        inbound.start(queue: queue); outbound.start(queue: queue)
    }

    private func pipe(_ from: NWConnection, _ to: NWConnection) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            if let data, !data.isEmpty { to.send(content: data, completion: .contentProcessed { _ in }) }
            if error != nil || isComplete { from.cancel(); to.cancel(); return }
            self?.pipe(from, to)
        }
    }

    func dropAll() {
        queue.sync { for (a, b) in pairs { a.cancel(); b.cancel() }; pairs.removeAll() }
    }

    func stop() { dropAll(); listener.cancel() }
}
