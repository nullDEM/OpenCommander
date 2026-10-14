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

/// Konflikt nazw: pomiń / zachowaj obie / zastąp. Zastąpienie nigdy nie jest domyślne.
struct ConflictSheet: View {
    let pending: PendingConflict
    let operations: OperationCenter
    @State private var applyToAll = false

    var body: some View {
        let c = pending.conflict
        VStack(alignment: .leading, spacing: 12) {
            Label("Element o tej nazwie już istnieje", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
            Text("W folderze docelowym znajduje się już „\(c.existing.lastPathComponent)”.")
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                GridRow { Text("Nowy (źródło)").font(.caption.weight(.semibold)); Text(Self.describe(c.source)) }
                GridRow { Text("Istniejący").font(.caption.weight(.semibold)); Text(Self.describe(c.existing)) }
            }
            .font(.callout).foregroundStyle(.secondary)
            Text(c.existing.deletingLastPathComponent().path)
                .font(.caption).foregroundStyle(.tertiary).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
            Toggle("Zastosuj do wszystkich kolejnych konfliktów w tej operacji", isOn: $applyToAll)
            Text("„Zastąp” przenosi istniejący element do Kosza.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Anuluj operację", role: .cancel) { operations.cancel(pending.jobID) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Pomiń") { operations.resolveConflict(ConflictDecision(.skip, applyToAll: applyToAll)) }
                Button("Zachowaj obie") { operations.resolveConflict(ConflictDecision(.keepBoth, applyToAll: applyToAll)) }
                    .keyboardShortcut(.defaultAction)
                Button("Zastąp…", role: .destructive) { operations.resolveConflict(ConflictDecision(.replace, applyToAll: applyToAll)) }
            }
        }
        .padding(20)
        .frame(width: 480)
        .interactiveDismissDisabled()
    }

    private static func describe(_ url: URL) -> String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return "niedostępny" }
        let isDir = (attrs[.type] as? FileAttributeType) == .typeDirectory
        let size = isDir ? "folder" : ProgressFormat.bytes((attrs[.size] as? NSNumber)?.int64Value ?? 0)
        let date = (attrs[.modificationDate] as? Date).map { PanelView.dateText($0) } ?? "—"
        return "\(size) · \(date)"
    }
}
