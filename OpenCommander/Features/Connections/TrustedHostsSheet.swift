import SwiftUI
import OpenCommanderCore

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
