import SwiftUI
import OpenCommanderCore

/// Pasek filtra bieżącego folderu (opcjonalnie z szukaniem w podfolderach).
struct PanelFilterBar: View {
    @Bindable var panel: PanelState
    @Binding var showFilter: Bool
    /// Fokus pola tekstowego filtra (należy do `PanelView`, bo ustawia go także skrót ⌘F).
    var isFieldFocused: FocusState<Bool>.Binding
    /// Fokus całego panelu — po zamknięciu filtra wraca na listę plików.
    var panelFocus: FocusState<PanelSide?>.Binding

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease.circle").foregroundStyle(.secondary)
            TextField(panel.searchSubfolders ? "Szukaj w tym folderze i podfolderach" : "Filtruj ten folder", text: $panel.filterText)
                .textFieldStyle(.plain)
                .focused(isFieldFocused)
                .onKeyPress(.escape) { closeFilter(); return .handled }
                .onSubmit { panelFocus.wrappedValue = panel.side }
                .accessibilityLabel("Wyszukiwanie nazw w bieżącym folderze")
            if panel.isSearching { ProgressView().controlSize(.small) }
            if panel.isFiltering {
                Text(resultsText)
                    .font(.caption).foregroundStyle(.secondary)
                    .help(panel.searchTruncated ? "Pokazano pierwsze wyniki — zawęź zapytanie" : "")
            }
            Toggle(isOn: $panel.searchSubfolders) { Image(systemName: "folder.badge.gearshape") }
                .toggleStyle(.button).buttonStyle(.borderless)
                .help("Szukaj także w podfolderach").accessibilityLabel("Szukaj w podfolderach")
            Button(action: closeFilter) { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
                .help("Zamknij filtr (Esc)").accessibilityLabel("Zamknij filtr")
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Color.primary.opacity(0.05))
    }

    private var resultsText: String {
        if panel.isRecursiveSearch {
            "\(panel.visibleEntries.count)\(panel.searchTruncated ? "+" : "") wyników"
        } else {
            "\(panel.visibleEntries.count) z \(panel.entries.count)"
        }
    }

    private func closeFilter() {
        panel.filterText = ""
        showFilter = false
        isFieldFocused.wrappedValue = false
        panelFocus.wrappedValue = panel.side
    }
}
