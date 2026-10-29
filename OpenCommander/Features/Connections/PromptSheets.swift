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

/// Hasło lub passphrase klucza, gdy nie jest zapisane w Keychain. Wartość żyje tylko w pamięci na czas sesji.
struct CredentialSheet: View {
    let request: PromptQueue<CredentialPrompt, String?>.Request
    @State private var value = ""
    @FocusState private var focused: Bool

    private var prompt: String {
        request.info.kind == .password
            ? "Podaj hasło dla \(request.info.profile.username)@\(request.info.profile.displayAddress)."
            : "Podaj hasło (passphrase) klucza prywatnego dla „\(request.info.profile.name)”."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(request.info.kind == .password ? "Hasło" : "Hasło do klucza", systemImage: "key.fill").font(.headline)
            Text(prompt).font(.callout).foregroundStyle(.secondary)
            SecureField(request.info.kind == .password ? "Hasło" : "Passphrase", text: $value)
                .textFieldStyle(.roundedBorder).focused($focused).onSubmit(submit)
            Text("Nie jest zapisywane na dysku. Zapisanie w Keychain wybierzesz w edycji połączenia.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Anuluj", role: .cancel) { request.answer(nil) }.keyboardShortcut(.cancelAction)
                Button("Połącz", action: submit).keyboardShortcut(.defaultAction).disabled(value.isEmpty)
            }
        }
        .padding(20).frame(width: 400)
        .onAppear { focused = true }
        .interactiveDismissDisabled()
    }

    private func submit() { guard !value.isEmpty else { return }; request.answer(value) }
}

/// Wspólne podpięcie okien pytań. Tylko jedno miejsce w hierarchii je prezentuje (`topLevel`), żeby nie powstały dwa arkusze naraz:
/// gdy otwarty jest inny arkusz (menedżer połączeń, formularz), pytania pojawiają się nad nim.
struct ConnectionPrompts: ViewModifier {
    let state: AppState
    let topLevel: Bool

    func body(content: Content) -> some View {
        content
            .sheet(item: Binding(get: { show ? state.hostKeyPrompts.current : nil }, set: { _ in })) { HostKeySheet(request: $0) }
            .sheet(item: Binding(get: { show ? state.credentialPrompts.current : nil }, set: { _ in })) { CredentialSheet(request: $0) }
    }

    private var show: Bool { topLevel ? state.sheet == nil : state.sheet != nil }
}

extension View {
    func connectionPrompts(_ state: AppState, topLevel: Bool) -> some View { modifier(ConnectionPrompts(state: state, topLevel: topLevel)) }
}
