import SwiftUI
import OpenCommanderCore

struct ConnectionRow: View {
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
