import SwiftUI
import QuickLook
import AppKit
import OpenCommanderCore

/// Tabela plików panelu: kolumny, zaznaczenie, sortowanie, przeciąganie, menu kontekstowe, skróty klawiszowe i Quick Look.
struct PanelTable: View {
    @Bindable var panel: PanelState
    let state: AppState
    var focus: FocusState<PanelSide?>.Binding

    /// Widoczność kolumn (prawy klik na nagłówku tabeli); zapamiętywana przez system.
    @SceneStorage("OpenCommander.columns.v2") private var columns: TableColumnCustomization<FileEntry>
    @State private var quickLookURL: URL?

    var body: some View {
        Table(of: FileEntry.self, selection: $panel.selection, sortOrder: $panel.sortComparators, columnCustomization: $columns) {
            TableColumn("Nazwa", value: \.name) { entry in
                NameCell(entry: entry, base: panel.isRecursiveSearch ? panel.location : nil)
            }
            .width(min: 90, ideal: 170)
            .customizationID("name")
            .disabledCustomizationBehavior(.visibility)
            TableColumn("Rozmiar", value: \.sortSize) { entry in
                Text(entry.size.map { ProgressFormat.bytes($0) } ?? "—")
                    .monospacedDigit().foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 50, ideal: 66, max: 120)
            .customizationID("size")
            TableColumn("Rodzaj", value: \.kind) { entry in
                Text(entry.kind).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 50, ideal: 90)
            .customizationID("kind")
            TableColumn("Zmodyfikowano", value: \.sortDate) { entry in
                Text(ModifiedDateText.string(for: entry.modificationDate))
                    .foregroundStyle(.secondary).lineLimit(1).monospacedDigit()
            }
            .width(min: 70, ideal: 110)
            .customizationID("date")
        } rows: {
            ForEach(panel.visibleEntries) { entry in
                TableRow(entry).draggable(draggedFiles(for: entry))
            }
        }
        .dropDestination(for: DraggedFiles.self) { items, _ in
            handleDrop(items.flatMap(\.urls))
            return !items.isEmpty
        }
        .dropDestination(for: URL.self) { urls, _ in
            handleDrop(urls.filter(\.isFileURL))
            return !urls.isEmpty
        }
        .contextMenu(forSelectionType: FileEntry.ID.self) { ids in
            PanelContextMenu(panel: panel, state: state, ids: ids, quickLookURL: $quickLookURL)
        } primaryAction: { ids in
            openItems(ids)
        }
        // Lista do przeglądania strzałkami potrzebna tylko przy otwartym podglądzie — nie budujemy jej przy każdym odświeżeniu widoku.
        .quickLookPreview($quickLookURL, in: (panel.isRemote || quickLookURL == nil) ? [] : panel.selectedEntries.map(\.url))
        .alternatingRowBackgrounds(.disabled)
        .focused(focus, equals: panel.side)
        .onKeyPress(phases: .down) { press in handleOptionShortcut(press) }
        .onKeyPress(.tab) {
            state.switchPanel()
            return .handled
        }
        .onKeyPress(.return) {
            guard !panel.selection.isEmpty else { return .ignored }
            state.open(panel.selectedEntries, in: panel)
            return .handled
        }
        .onKeyPress(.space) {
            // Spacja: szybki podgląd zaznaczonego elementu (system zamyka go tą samą Spacją).
            guard !panel.isRemote, let first = panel.selectedEntries.first else { return .ignored }
            quickLookURL = first.url
            return .handled
        }
        .overlay { PanelEmptyOverlay(panel: panel) }
    }

    /// Przeciągany jest cały zaznaczony zbiór, jeśli chwycony wiersz do niego należy; inaczej tylko ten wiersz.
    private func draggedFiles(for entry: FileEntry) -> DraggedFiles {
        let items = panel.selection.contains(entry.id) ? panel.selectedEntries : [entry]
        return DraggedFiles(urls: items.map(\.url))
    }

    private func handleDrop(_ urls: [URL]) {
        state.handleDrop(urls, onto: panel, optionHeld: NSEvent.modifierFlags.contains(.option))
    }

    private func openItems(_ ids: Set<FileEntry.ID>) {
        state.active = panel.side
        state.open(panel.visibleEntries.filter { ids.contains($0.id) }, in: panel)
    }

    /// ⌥C / ⌥V jako dodatkowe skróty kopiowania i wklejania plików (⌥ zmienia znak na ç / √).
    private func handleOptionShortcut(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers == .option else { return .ignored }
        let ch = press.characters.lowercased()
        if ch == "c" || ch == "ç" { state.copyFilesToClipboard(); return .handled }
        if ch == "v" || ch == "√" { state.pasteFilesFromClipboard(); return .handled }
        return .ignored
    }
}
