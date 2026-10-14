import SwiftUI
import OpenCommanderCore

/// Szukanie duplikatów po zawartości w folderze aktywnego panelu (i podfolderach). Rusza dopiero po kliknięciu.
struct DuplicatesSheet: View {
    let root: URL
    let state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var groups: [DuplicateGroup] = []
    @State private var marked = Set<URL>()
    @State private var phase: String?
    @State private var progress: (Int, Int) = (0, 0)
    @State private var finished = false
    @State private var task: Task<Void, Never>?
    @State private var confirmTrash = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Duplikaty w „\(root.lastPathComponent)”").font(.headline)
            Text("Porównuje zawartość plików (SHA-256) w tym folderze i podfolderach. Nic nie jest usuwane bez Twojego potwierdzenia — pliki trafiają do Kosza.")
                .font(.callout).foregroundStyle(.secondary)

            if let phase {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(progress.1 > 0 ? "\(phase): \(progress.0) z \(progress.1)" : "\(phase)…")
                    Spacer()
                    Button("Przerwij") { task?.cancel() }
                }
            }

            if finished && groups.isEmpty && phase == nil {
                Text("Nie znaleziono duplikatów.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 200)
            } else {
                List {
                    ForEach(groups) { g in
                        Section("\(ProgressFormat.bytes(g.size)) · \(g.files.count) kopii · do odzyskania \(ProgressFormat.bytes(g.wastedBytes))") {
                            ForEach(g.files, id: \.url) { f in
                                Toggle(isOn: Binding(get: { marked.contains(f.url) },
                                                     set: { if $0 { marked.insert(f.url) } else { marked.remove(f.url) } })) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(f.url.lastPathComponent).lineLimit(1)
                                        Text(relative(f.url) + (f.modificationDate.map { " · " + $0.formatted(date: .abbreviated, time: .shortened) } ?? ""))
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(minHeight: 260)
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Button(finished ? "Szukaj ponownie" : "Szukaj duplikatów") { start() }.disabled(phase != nil)
                Button("Zaznacz wszystkie oprócz najstarszych") {
                    marked = Set(groups.flatMap { $0.files.dropFirst().map(\.url) })
                }.disabled(groups.isEmpty)
                Spacer()
                Button("Zamknij") { task?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Button("Do Kosza (\(marked.count))…", role: .destructive) { requestTrash() }
                    .disabled(marked.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 700, minHeight: 500)
        .confirmationDialog("Przenieść \(Polish.items(marked.count)) do Kosza?", isPresented: $confirmTrash, titleVisibility: .visible) {
            Button("Przenieś do Kosza", role: .destructive) {
                state.trashURLs(Array(marked))
                dismiss()
            }
            Button("Anuluj", role: .cancel) {}
        } message: { Text("W każdej grupie zostanie co najmniej jedna kopia. Pliki można przywrócić z Kosza.") }
    }

    private func relative(_ url: URL) -> String {
        let p = url.deletingLastPathComponent().path
        return p.hasPrefix(root.path) ? "." + p.dropFirst(root.path.count) : p
    }

    /// Nigdy nie pozwalamy zaznaczyć wszystkich kopii w grupie — jedna zawsze zostaje.
    private func requestTrash() {
        if let bad = groups.first(where: { g in g.files.allSatisfy { marked.contains($0.url) } }) {
            error = "W grupie „\(bad.files[0].url.lastPathComponent)” zaznaczono wszystkie kopie. Odznacz co najmniej jedną."
            return
        }
        error = nil
        confirmTrash = true
    }

    private func start() {
        groups = []; marked = []; finished = false; error = nil
        phase = "Skanowanie folderów"; progress = (0, 0)
        let hidden = state.showHidden
        task = Task {
            do {
                let result = try await DuplicateFinder.find(in: root, showHidden: hidden) { p in
                    Task { @MainActor in phase = p.phase; progress = (p.done, p.total) }
                }
                groups = result
                finished = true
            } catch is CancellationError {
                finished = false
            } catch {
                self.error = error.localizedDescription
            }
            phase = nil
        }
    }
}
