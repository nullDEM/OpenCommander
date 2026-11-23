import SwiftUI
import OpenCommanderCore

/// Pasek narzędzi jako osobny typ: czyta zaznaczenie aktywnego panelu (`canCopy`, `canMove`, `selection`),
/// więc jego odczyty unieważniają tylko ten pasek, a nie całe okno z oboma panelami.
struct MainToolbar: ToolbarContent {
    @Bindable var state: AppState

    var body: some ToolbarContent {
        ToolbarItemGroup {
            Button { state.requestNewFolder() } label: { Label("Nowy folder", systemImage: "folder.badge.plus") }
                .help("Nowy folder (⇧⌘N)")
            Button { state.requestRename() } label: { Label("Zmień nazwę", systemImage: "pencil") }
                .help("Zmień nazwę (F2)")
                .disabled(state.activePanel.selection.count != 1)
        }
        ToolbarItemGroup {
            Button { state.transferSelection(.copy) } label: { Label("Kopiuj do drugiego panelu", systemImage: "doc.on.doc") }
                .help("Kopiuj do drugiego panelu (F5)")
                .disabled(!state.canCopy)
            Button { state.transferSelection(.move) } label: { Label("Przenieś do drugiego panelu", systemImage: "arrow.right.doc.on.clipboard") }
                .help("Przenieś do drugiego panelu (F6)")
                .disabled(!state.canMove)
            Button { state.requestTrash() } label: { Label(state.activePanel.isRemote ? "Usuń z serwera" : "Przenieś do Kosza", systemImage: "trash") }
                .help(state.activePanel.isRemote ? "Usuń z serwera (⌘⌫) — nie trafia do Kosza" : "Przenieś do Kosza (⌘⌫)")
                .disabled(state.activePanel.selection.isEmpty)
        }
        ToolbarItemGroup {
            Toggle(isOn: $state.showsLeftPanel) { Label("Lewy panel", systemImage: "rectangle.lefthalf.inset.filled") }
                .help(state.showsLeftPanel ? "Ukryj lewy panel (⌥⌘←)" : "Pokaż lewy panel (⌥⌘←)")
                .disabled(!state.panelVisibility.canToggle(.left))
            Toggle(isOn: $state.showsRightPanel) { Label("Prawy panel", systemImage: "rectangle.righthalf.inset.filled") }
                .help(state.showsRightPanel ? "Ukryj prawy panel (⌥⌘→)" : "Pokaż prawy panel (⌥⌘→)")
                .disabled(!state.panelVisibility.canToggle(.right))
        }
        ToolbarItemGroup {
            Toggle(isOn: $state.showHiddenFiles) {
                Label("Pliki ukryte", systemImage: state.showHidden ? "eye" : "eye.slash")
            }
            .help("Pokaż / ukryj pliki ukryte (⇧⌘.)")
            Button { state.activePanel.reload() } label: { Label("Odśwież", systemImage: "arrow.clockwise") }
                .help("Odśwież (⌘R)")
            Toggle(isOn: $state.showInspector) { Label("Informacje", systemImage: "info.circle") }
                .help("Panel informacji (⌘I)")
        }
    }
}
