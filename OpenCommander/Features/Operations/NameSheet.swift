import SwiftUI
import OpenCommanderCore

/// Arkusz z jednym polem tekstowym (nowy folder, zmiana nazwy). Enter = zatwierdź, Esc = anuluj.
struct NameSheet: View {
    let title: String
    let message: String
    let initial: String
    let confirmTitle: String
    let onSubmit: (String) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error: String?
    @State private var working = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            Text(message).font(.callout).foregroundStyle(.secondary)
            TextField("Nazwa", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(submit)
                .accessibilityLabel("Nazwa")
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Anuluj", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(confirmTitle, action: submit).keyboardShortcut(.defaultAction).disabled(working)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { text = initial; focused = true }
    }

    private func submit() {
        guard !working else { return }
        working = true
        Task {
            let result = await onSubmit(text)
            working = false
            if let result { error = result } else { dismiss() }
        }
    }
}
