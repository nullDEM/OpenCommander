import SwiftUI
import OpenCommanderCore

/// Porównanie folderów obu paneli (nazwa, rodzaj, rozmiar, data — bez czytania zawartości) i kopiowanie różnic.
struct CompareSheet: View {
    let state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var diff: FolderDiff?
    @State private var loading = true
    @State private var selection = Set<ComparisonItem.ID>()
    @State private var filter: Filter = .all
    @State private var left = URL(fileURLWithPath: "/")
    @State private var right = URL(fileURLWithPath: "/")

    enum Filter: String, CaseIterable, Identifiable {
        case all = "Wszystkie", onlyLeft = "Tylko lewy", onlyRight = "Tylko prawy", differs = "Różnią się"
        var id: String { rawValue }
    }

    private var shown: [ComparisonItem] {
        guard let diff else { return [] }
        switch filter {
        case .all: return diff.items
        case .onlyLeft: return diff.items.filter { $0.state == .onlyLeft }
        case .onlyRight: return diff.items.filter { $0.state == .onlyRight }
        case .differs: return diff.items.filter { $0.state == .differs }
        }
    }
    private var chosen: [ComparisonItem] { shown.filter { selection.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Porównanie folderów").font(.headline)
            VStack(alignment: .leading, spacing: 2) {
                Label(left.path, systemImage: "arrow.left.square").lineLimit(1).truncationMode(.head)
                Label(right.path, systemImage: "arrow.right.square").lineLimit(1).truncationMode(.head)
            }
            .font(.callout).foregroundStyle(.secondary)

            Picker("Pokaż", selection: $filter) {
                ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()

            ZStack {
                Table(shown, selection: $selection) {
                    TableColumn("Ścieżka") { item in
                        Label(item.relativePath, systemImage: item.isDirectory ? "folder" : "doc")
                            .lineLimit(1).truncationMode(.middle)
                    }
                    .width(min: 160, ideal: 300)
                    TableColumn("Stan") { item in
                        switch item.state {
                        case .onlyLeft: Text("tylko po lewej").foregroundStyle(.blue)
                        case .onlyRight: Text("tylko po prawej").foregroundStyle(.purple)
                        case .differs: Text("różni się").foregroundStyle(.orange)
                        }
                    }
                    .width(min: 90, ideal: 110)
                    TableColumn("Lewy") { Text(describe($0.leftSize, $0.leftDate)).foregroundStyle(.secondary).lineLimit(1) }
                    TableColumn("Prawy") { Text(describe($0.rightSize, $0.rightDate)).foregroundStyle(.secondary).lineLimit(1) }
                }
                if loading { ProgressView("Porównuję…") }
                else if shown.isEmpty { Text(diff?.items.isEmpty == true ? "Foldery są takie same." : "Brak pozycji w tym widoku.").foregroundStyle(.secondary) }
            }
            .frame(minHeight: 260)

            if let diff {
                Text("Takie same: \(diff.identical) · różnice: \(diff.items.count)"
                     + (diff.skipped > 0 ? " · pominięto \(diff.skipped) (dowiązania lub brak dostępu)" : "")
                     + (diff.truncated ? " · wynik obcięty — zawęź foldery" : ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Kopiuj zaznaczone →") { copy(from: left, to: right, items: chosen.filter { $0.state != .onlyRight }) }
                    .disabled(chosen.filter { $0.state != .onlyRight }.isEmpty)
                    .help("Kopiuje zaznaczone z lewego folderu do prawego. Przy różnicach zapyta o konflikt — nic nie jest nadpisywane bez Twojej decyzji.")
                Button("← Kopiuj zaznaczone") { copy(from: right, to: left, items: chosen.filter { $0.state != .onlyLeft }) }
                    .disabled(chosen.filter { $0.state != .onlyLeft }.isEmpty)
                Spacer()
                Button("Odśwież") { load() }.disabled(loading)
                Button("Zamknij") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 520)
        .onAppear {
            left = state.left.location; right = state.right.location
            load()
        }
    }

    private func describe(_ size: Int64?, _ date: Date?) -> String {
        guard size != nil || date != nil else { return "—" }
        let s = size.map { ProgressFormat.bytes($0) } ?? ""
        let d = date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? ""
        return [s, d].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func load() {
        loading = true; selection = []
        let l = left, r = right
        Task {
            let result = try? await FolderComparison.compare(left: l, right: r)
            diff = result ?? FolderDiff()
            loading = false
        }
    }

    private func copy(from: URL, to: URL, items: [ComparisonItem]) {
        state.copyDifferences(items, from: from, to: to)
        dismiss()
    }
}
