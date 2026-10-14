import SwiftUI

struct AppCommands: Commands {
    let state: AppState
    @Environment(\.openWindow) private var openWindow

    private var fKey: (Int) -> KeyEquivalent = { n in KeyEquivalent(Character(UnicodeScalar(0xF704 + n - 1)!)) }

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Skróty klawiszowe") { openWindow(id: "shortcuts") }
                .keyboardShortcut("/", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .newItem) {
            Button("Nowy folder") { state.requestNewFolder() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(state.isBusyWithDialog)
            Button("Wybierz folder…") { state.chooseFolder() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(state.isBusyWithDialog)
        }
        CommandGroup(replacing: .pasteboard) {
            Button("Wytnij") { NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil) }
                .keyboardShortcut("x", modifiers: .command)
            Button("Kopiuj") {
                if state.textFieldHasFocus { NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) }
                else { state.copyFilesToClipboard() }
            }
            .keyboardShortcut("c", modifiers: .command)
            Button("Wklej") {
                if state.textFieldHasFocus { NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) }
                else { state.pasteFilesFromClipboard() }
            }
            .keyboardShortcut("v", modifiers: .command)
            Button("Zaznacz wszystko") { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) }
                .keyboardShortcut("a", modifiers: .command)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Zamknij kartę") { state.closeActiveTabOrWindow() }
                .keyboardShortcut("w", modifiers: .command)
        }
        CommandMenu("Karty") {
            Button("Nowa karta") { state.newTab() }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(state.isBusyWithDialog)
            Button("Następna karta") { state.nextTab() }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(state.isBusyWithDialog || state.activeTabs.tabs.count < 2)
            Button("Poprzednia karta") { state.previousTab() }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(state.isBusyWithDialog || state.activeTabs.tabs.count < 2)
        }
        CommandMenu("Przestrzenie") {
            Button("Zapisz bieżącą przestrzeń…") { state.requestSaveWorkspace() }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(state.isBusyWithDialog)
            if !state.workspaces.isEmpty {
                Divider()
                ForEach(state.workspaces) { w in
                    Button(w.name) { state.applyWorkspace(w) }.disabled(state.isBusyWithDialog)
                }
                Divider()
                Menu("Usuń przestrzeń") {
                    ForEach(state.workspaces) { w in Button(w.name, role: .destructive) { state.deleteWorkspace(w) } }
                }
            }
        }
        CommandMenu("Plik") {
            Button("Otwórz") { state.openSelection() }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(state.isBusyWithDialog || state.activePanel.selection.isEmpty)
            Button("Zmień nazwę…") { state.requestRename() }
                .keyboardShortcut(fKey(2), modifiers: [])
                .disabled(state.isBusyWithDialog || state.activePanel.selection.count != 1)
            Divider()
            Button("Kopiuj do drugiego panelu") { state.transferSelection(.copy) }
                .keyboardShortcut(fKey(5), modifiers: [])
                .disabled(state.isBusyWithDialog || !state.canCopy)
            Button("Przenieś do drugiego panelu") { state.transferSelection(.move) }
                .keyboardShortcut(fKey(6), modifiers: [])
                .disabled(state.isBusyWithDialog || !state.canMove)
            Button("Przenieś do Kosza") { state.requestTrash() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(state.isBusyWithDialog || state.activePanel.selection.isEmpty)
            Divider()
            Button(state.ejectableVolumeOfActivePanel.map { "Wysuń „\($0.name)”" } ?? "Wysuń wolumin") { state.ejectActivePanelVolume() }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(state.isBusyWithDialog || state.ejectableVolumeOfActivePanel == nil)
            Button("Pokaż w Finderze") { state.revealInFinder() }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(state.isBusyWithDialog)
            Button("Kopiuj ścieżkę") { state.copyPathToPasteboard() }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(state.isBusyWithDialog)
        }
        CommandMenu("Narzędzia") {
            Button("Zmień nazwy zaznaczonych…") { state.requestBatchRename() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(state.isBusyWithDialog || state.activePanel.selection.isEmpty)
            Button("Porównaj foldery obu paneli…") { state.requestCompare() }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(state.isBusyWithDialog || state.left.location == state.right.location)
            Button("Znajdź duplikaty w tym folderze…") { state.requestDuplicates() }
                .disabled(state.isBusyWithDialog)
        }
        CommandMenu("Widok") {
            Button("Odśwież") { state.activePanel.reload() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(state.isBusyWithDialog)
            Button("Filtruj folder") { state.requestFilter() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(state.isBusyWithDialog)
            Toggle("Panel informacji", isOn: Binding(get: { state.showInspector }, set: { state.showInspector = $0 }))
                .keyboardShortcut("i", modifiers: .command)
            Toggle("Pokaż pliki ukryte", isOn: Binding(get: { state.showHidden }, set: { state.setShowHidden($0) }))
                .keyboardShortcut(".", modifiers: [.command, .shift])
        }
        CommandMenu("Przejdź") {
            Button("Folder nadrzędny") { state.activePanel.goUp() }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(state.isBusyWithDialog || !state.activePanel.canGoUp)
            Button("Wstecz") { state.activePanel.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(state.isBusyWithDialog || !state.activePanel.canGoBack)
            Button("Dalej") { state.activePanel.goForward() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(state.isBusyWithDialog || !state.activePanel.canGoForward)
            Button(state.isFavorite(state.activePanel.location) ? "Usuń folder z ulubionych" : "Dodaj folder do ulubionych") {
                state.toggleFavoriteForActivePanel()
            }
            .keyboardShortcut("d", modifiers: .command)
            .disabled(state.isBusyWithDialog)
            Divider()
            Button("Przełącz panel") { state.switchPanel() }
                .keyboardShortcut("`", modifiers: .command)
        }
    }
}
