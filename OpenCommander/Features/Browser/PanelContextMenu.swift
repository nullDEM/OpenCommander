import SwiftUI
import AppKit
import OpenCommanderCore

/// Menu kontekstowe tabeli plików: dla zaznaczenia (otwórz, kopiuj, przenieś, usuń…) albo dla pustego miejsca.
struct PanelContextMenu: View {
    let panel: PanelState
    let state: AppState
    let ids: Set<FileEntry.ID>
    @Binding var quickLookURL: URL?

    var body: some View {
        let entries = panel.visibleEntries.filter { ids.contains($0.id) }
        if entries.isEmpty {
            Button("Nowy folder") { state.active = panel.side; state.requestNewFolder() }
            Button("Odśwież") { panel.reload() }
            Button(state.showHidden ? "Ukryj pliki ukryte" : "Pokaż pliki ukryte") { state.setShowHidden(!state.showHidden) }
        } else {
            selectionItems(entries)
        }
    }

    @ViewBuilder
    private func selectionItems(_ entries: [FileEntry]) -> some View {
        Button("Otwórz") { state.select(ids, in: panel); state.open(entries, in: panel) }
        if !panel.isRemote, entries.count == 1, !entries[0].isNavigable {
            OpenWithMenu(state: state, url: entries[0].url)
        }
        if !panel.isRemote {
            Button("Szybki podgląd") { state.select(ids, in: panel); quickLookURL = entries.first?.url }
            Divider()
            Button("Pokaż w Finderze") { NSWorkspace.shared.activateFileViewerSelecting(entries.map(\.url)) }
        } else {
            Divider()
        }
        Button("Kopiuj ścieżkę") { state.select(ids, in: panel); state.copyPathToPasteboard() }
        Button("Informacje") { state.select(ids, in: panel); state.showInspector = true }
        if entries.count == 1, entries[0].isNavigable, !panel.isRemote {
            Button("Otwórz w nowej karcie") { state.select(ids, in: panel); state.openInNewTab(entries[0].url) }
            if state.isFavorite(entries[0].url) {
                Button("Usuń z ulubionych") { state.removeFavorite(entries[0].url) }
            } else {
                Button("Dodaj do ulubionych") { state.addFavorite(entries[0].url) }
            }
        }
        Divider()
        Button(copyTitle) { state.select(ids, in: panel); state.transferSelection(.copy) }
            .disabled(!state.canCopy)
        Button("Przenieś do drugiego panelu") { state.select(ids, in: panel); state.transferSelection(.move) }
            .disabled(!state.panelVisibility.isVisible(panel.side.other) || state.anyPanelRemote || panel.location == state.panel(panel.side.other).location)
        if entries.count == 1 { Button("Zmień nazwę…") { state.select(ids, in: panel); state.requestRename() } }
        Divider()
        Button(panel.isRemote ? "Usuń z serwera…" : "Przenieś do Kosza", role: .destructive) { state.select(ids, in: panel); state.requestTrash() }
    }

    private var copyTitle: String {
        if panel.isRemote { "Pobierz do drugiego panelu" }
        else if state.panel(panel.side.other).isRemote { "Wyślij na serwer (drugi panel)" }
        else { "Kopiuj do drugiego panelu" }
    }
}
