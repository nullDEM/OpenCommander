import SwiftUI
import OpenCommanderCore

/// Zaufanie do klucza serwera przy pierwszym połączeniu. Domyślną akcją jest odmowa — zaufanie wymaga świadomego kliknięcia.
struct HostKeySheet: View {
    let request: PromptQueue<HostKeyInfo, Bool>.Request

    var body: some View {
        let i = request.info
        VStack(alignment: .leading, spacing: 12) {
            Label("Nieznany serwer SSH", systemImage: "lock.trianglebadge.exclamationmark").font(.headline)
            Text("Łączysz się z tym serwerem po raz pierwszy. Zaufaj mu tylko wtedy, gdy odcisk klucza zgadza się z tym, który podał administrator serwera.")
                .font(.callout).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                GridRow { Text("Serwer").font(.caption.weight(.semibold)); Text("\(i.host):\(i.port)") }
                GridRow { Text("Typ klucza").font(.caption.weight(.semibold)); Text(i.keyType) }
                GridRow(alignment: .top) {
                    Text("Odcisk").font(.caption.weight(.semibold))
                    Text(i.fingerprint).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                }
            }
            Text("Zaufanie zostanie zapisane dopiero po Twojej zgodzie. Później możesz je usunąć w „Zaufane serwery”.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Nie ufaj", role: .cancel) { request.answer(false) }.keyboardShortcut(.defaultAction)
                Button("Zaufaj i połącz", role: .destructive) { request.answer(true) }
            }
        }
        .padding(20).frame(width: 480)
        .interactiveDismissDisabled()
    }
}
