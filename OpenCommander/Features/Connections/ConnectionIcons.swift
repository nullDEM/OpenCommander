import OpenCommanderCore

enum ConnectionIcons {
    static func symbol(_ p: ConnectionProfile) -> String {
        p.isEncrypted ? "externaldrive.connected.to.line.below" : "externaldrive.badge.exclamationmark"
    }
    static func statusText(_ s: ConnectionManager.State) -> String {
        switch s {
        case .disconnected: return "rozłączono"
        case .connecting: return "łączenie…"
        case .connected: return "połączono"
        case .failed: return "błąd"
        }
    }
}
