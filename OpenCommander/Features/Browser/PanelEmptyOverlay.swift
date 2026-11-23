import SwiftUI
import OpenCommanderCore

/// Komunikat nad pustą tabelą (pusty folder, brak wyników filtra, brak widocznych elementów).
struct PanelEmptyOverlay: View {
    let panel: PanelState

    var body: some View {
        if panel.visibleEntries.isEmpty && !panel.isLoading && !panel.isSearching && panel.loadError == nil {
            VStack(spacing: 6) {
                Image(systemName: panel.isFiltering ? "magnifyingglass" : "tray")
                    .font(.largeTitle).foregroundStyle(.tertiary)
                Text(message).foregroundStyle(.secondary)
            }
            .allowsHitTesting(false)
        }
    }

    private var message: String {
        if panel.isFiltering { "Brak wyników dla „\(panel.filterText)”" }
        else if panel.showHidden { "Folder jest pusty" }
        else { "Brak widocznych elementów" }
    }
}
