import SwiftUI
import OpenCommanderCore

/// Lista zapisanych połączeń: połącz / rozłącz / edytuj / usuń.
struct ConnectionsManagerSheet: View {
    let state: AppState
    @Environment(\.dismiss) private var dismiss
    /// Profil, o którego usunięcie pytamy; okno potwierdzenia pokazuje osobna flaga, a dane trafiają do niego przez `presenting:`.
    @State private var pendingDelete: ConnectionProfile?
    @State private var isConfirmingDelete = false

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
                        ConnectionRow(profile: p, state: state, onDelete: { pendingDelete = p; isConfirmingDelete = true })
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
        .confirmationDialog(deleteTitle, isPresented: $isConfirmingDelete, titleVisibility: .visible, presenting: pendingDelete) { p in
            if manager.exclusiveSecretCount(of: p.id) > 0 {
                Button("Usuń profil i zapisane hasło z Keychain", role: .destructive) { state.removeConnection(p.id, deleteSecrets: true) }
                Button("Usuń tylko profil (zostaw hasło w Keychain)") { state.removeConnection(p.id, deleteSecrets: false) }
            } else {
                Button("Usuń profil", role: .destructive) { state.removeConnection(p.id, deleteSecrets: false) }
            }
            Button("Anuluj", role: .cancel) {}
        } message: { _ in
            Text("Pliki na serwerze nie zostaną ruszone. Sekrety używane także przez inny profil nigdy nie są usuwane.")
        }
    }

    private var deleteTitle: String { "Usunąć połączenie „\(pendingDelete?.name ?? "")”?" }
}
