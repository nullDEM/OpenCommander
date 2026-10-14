import SwiftUI
import OpenCommanderCore

/// Lista zapisanych połączeń: połącz / rozłącz / edytuj / usuń.
struct ConnectionsManagerSheet: View {
    let state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var pendingDelete: ConnectionProfile?

    var body: some View {
        let manager = state.connections
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Połączenia").font(.headline)
                Spacer()
                Button { state.sheet = .editConnection(nil) } label: { Label("Nowe połączenie", systemImage: "plus") }
            }
            if manager.profiles.isEmpty {
                Text("Brak zapisanych połączeń. Dodaj pierwsze przyciskiem „Nowe połączenie”.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 120)
            } else {
                List {
                    ForEach(manager.profiles) { p in
                        ConnectionRow(profile: p, state: state, onDelete: { pendingDelete = p })
                    }
                }
                .frame(minHeight: 180)
            }
            HStack {
                Button("Zaufane serwery SSH…") { state.sheet = .trustedHosts }
                Spacer()
                Button("Zamknij") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 560)
        .connectionPrompts(state, topLevel: false)
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            if let p = pendingDelete {
                let n = manager.exclusiveSecretCount(of: p.id)
                if n > 0 {
                    Button("Usuń profil i zapisane hasło z Keychain", role: .destructive) { state.removeConnection(p.id, deleteSecrets: true); pendingDelete = nil }
                    Button("Usuń tylko profil (zostaw hasło w Keychain)") { state.removeConnection(p.id, deleteSecrets: false); pendingDelete = nil }
                } else {
                    Button("Usuń profil", role: .destructive) { state.removeConnection(p.id, deleteSecrets: false); pendingDelete = nil }
                }
            }
            Button("Anuluj", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("Pliki na serwerze nie zostaną ruszone. Sekrety używane także przez inny profil nigdy nie są usuwane.")
        }
    }

    private var deleteTitle: String { "Usunąć połączenie „\(pendingDelete?.name ?? "")”?" }
}

private struct ConnectionRow: View {
    let profile: ConnectionProfile
    let state: AppState
    let onDelete: () -> Void

    var body: some View {
        let st = state.connections.state(profile.id)
        HStack(spacing: 8) {
            Image(systemName: ConnectionIcons.symbol(profile)).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.name).lineLimit(1)
                Text("\(profile.proto.title) · \(profile.displayAddress)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if case .failed(let msg) = st { Text(msg).font(.caption).foregroundStyle(.red).lineLimit(2) }
                if !profile.isEncrypted { Label("bez szyfrowania", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange) }
            }
            Spacer()
            Text(ConnectionIcons.statusText(st)).font(.caption).foregroundStyle(.secondary)
            if st == .connected {
                Button("Rozłącz") { state.disconnect(profile.id) }
            } else {
                Button("Połącz") { state.sheet = nil; state.openConnection(profile.id) }.disabled(st == .connecting)
            }
            Button { state.sheet = .editConnection(profile) } label: { Image(systemName: "pencil") }
                .buttonStyle(.borderless).help("Edytuj").accessibilityLabel("Edytuj połączenie")
            Button(action: onDelete) { Image(systemName: "trash") }
                .buttonStyle(.borderless).help("Usuń profil").accessibilityLabel("Usuń połączenie")
        }
    }
}

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

/// Zaufane klucze serwerów SSH: podgląd i usuwanie (następne połączenie ponownie zapyta o zaufanie).
struct TrustedHostsSheet: View {
    let state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var hosts: TrustedHosts = TrustedHosts()
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Zaufane serwery SSH").font(.headline)
            Text("To własna lista aplikacji (nie systemowy plik known_hosts). Usunięcie wpisu powoduje ponowne pytanie przy następnym połączeniu.")
                .font(.callout).foregroundStyle(.secondary)
            if hosts.entries.isEmpty {
                Text("Brak zaufanych serwerów.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 100)
            } else {
                List {
                    ForEach(hosts.entries) { e in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(e.host):\(e.port)")
                                Text("\(e.keyType) · \(e.fingerprint)").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                                    .textSelection(.enabled).lineLimit(2)
                            }
                            Spacer()
                            Button("Usuń zaufanie", role: .destructive) { remove(e) }
                        }
                    }
                }
                .frame(minHeight: 160)
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack { Spacer(); Button("Zamknij") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20).frame(width: 560)
        .onAppear { hosts = state.connections.trustedHostsStore.load() }
    }

    private func remove(_ e: TrustedHosts.Entry) {
        var h = state.connections.trustedHostsStore.load()
        h.remove(id: e.id)
        do { try state.connections.trustedHostsStore.save(h); hosts = h } catch { self.error = "Nie udało się zapisać listy: \(error.localizedDescription)" }
    }
}
