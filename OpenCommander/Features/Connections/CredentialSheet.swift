import SwiftUI
import OpenCommanderCore

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
