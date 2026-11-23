import SwiftUI
import OpenCommanderCore

/// Pasek stanu panelu: liczba elementów, podsumowanie zaznaczenia i wolne miejsce na woluminie.
/// Osobny widok, więc zmiana zaznaczenia przelicza tylko ten pasek (i tabelę), a nie cały panel.
struct PanelStatusBar: View {
    let panel: PanelState

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                Text(statusText).lineLimit(1)
                Spacer(minLength: 8)
                if let free = panel.freeSpace {
                    Label("\(ProgressFormat.bytes(free)) wolne", systemImage: "internaldrive")
                        .labelStyle(.titleAndIcon).lineLimit(1)
                        .help("Wolne miejsce na woluminie tego folderu")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.bar)
        }
        .accessibilityElement(children: .combine)
    }

    private var statusText: String {
        let total = panel.isFiltering
            ? "\(Polish.items(panel.visibleEntries.count)) z \(panel.entries.count) (filtr)"
            : Polish.items(panel.entries.count)
        guard !panel.selection.isEmpty else { return total }
        let sel = panel.selectionSummary   // jedno przejście po liście zamiast kilku
        var s = "Zaznaczono \(sel.count) z \(total)"
        if sel.knownSize > 0 || sel.withUnknownSize == 0 {
            s += " · \(ProgressFormat.bytes(sel.knownSize))"
        }
        if sel.withUnknownSize > 0 { s += " (rozmiary folderów nie są liczone)" }
        return s
    }
}
