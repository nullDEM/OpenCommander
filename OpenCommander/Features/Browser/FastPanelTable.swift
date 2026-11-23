import SwiftUI
import AppKit
import OpenCommanderCore

/// Lista plików na `NSTableView` (macOS 15+). Tabela SwiftUI przy każdej aktualizacji odwiedza wszystkie wiersze
/// (ok. 0,6 s na 50 000 wpisów na wątku głównym); `NSTableView` tworzy widoki tylko dla widocznych wierszy.
///
/// Zachowanie jak w `PanelTable`: te same kolumny (z wyborem widoczności w menu nagłówka), sortowanie przez `setSort`,
/// zaznaczenie w `panel.selection`, to samo menu kontekstowe (`PanelContextMenu` przez `NSHostingMenu`), Quick Look,
/// przeciąganie między panelami, upuszczanie plików z Findera, skróty Tab / Return / Spacja / ⌥C / ⌥V.
/// Przeciąganie *do innych programów* jest wyłączone — tak jak dotąd.
@available(macOS 15.0, *)
struct FastPanelTable: View {
    let panel: PanelState
    let state: AppState
    var focus: FocusState<PanelSide?>.Binding
    @State private var quickLookURL: URL?

    var body: some View {
        FileTableRepresentable(
            panel: panel, state: state,
            entries: panel.visibleEntries, selection: panel.selection,
            sortKey: panel.sortKey, sortAscending: panel.sortAscending,
            isActive: state.active == panel.side,
            base: panel.isRecursiveSearch ? panel.location : nil,
            quickLookURL: $quickLookURL
        )
        .quickLookPreview($quickLookURL, in: (panel.isRemote || quickLookURL == nil) ? [] : panel.selectedEntries.map(\.url))
        // Bez `.focused`: fokus AppKit nadany tabeli przez okno przy starcie przestawiałby aktywny panel.
        // Aktywny panel zmienia klik w tabelę i Tab (`FileTableView`), a fokus podąża za `state.active`.
        .overlay { PanelEmptyOverlay(panel: panel) }
    }
}

/// Komórka nazwy wyrównana do lewej (ten sam widok co w tabeli SwiftUI).
private struct NameCellRow: View {
    let entry: FileEntry
    let base: URL?
    var body: some View {
        NameCell(entry: entry, base: base).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 2)
    }
}

@available(macOS 15.0, *)
private struct FileTableRepresentable: NSViewRepresentable {
    let panel: PanelState
    let state: AppState
    let entries: [FileEntry]
    let selection: Set<FileEntry.ID>
    let sortKey: SortKey
    let sortAscending: Bool
    let isActive: Bool
    let base: URL?
    @Binding var quickLookURL: URL?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = FileTableView()
        table.coordinator = context.coordinator
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = false
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.allowsColumnSelection = false // klik w nagłówek ma sortować, nie zaznaczać kolumny (i kasować zaznaczenia wierszy)
        table.allowsTypeSelect = true
        table.usesAutomaticRowHeights = false
        table.rowHeight = 22
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        for spec in Coordinator.columns {
            let column = NSTableColumn(identifier: spec.id)
            column.title = spec.title
            column.minWidth = spec.min
            column.width = spec.ideal
            if let max = spec.max { column.maxWidth = max }
            column.sortDescriptorPrototype = NSSortDescriptor(key: spec.key.rawValue, ascending: true)
            if spec.key == .size { column.headerCell.alignment = .right }
            column.resizingMask = spec.key == .name ? [.autoresizingMask, .userResizingMask] : .userResizingMask
            table.addTableColumn(column)
        }
        // Szerokość, kolejność i widoczność kolumn zapamiętuje AppKit — osobno dla każdego panelu.
        table.autosaveName = "OpenCommander.fileTable.\(panel.side == .left ? "left" : "right")"
        table.autosaveTableColumns = true
        let headerMenu = NSMenu()
        headerMenu.delegate = context.coordinator
        table.headerView?.menu = headerMenu
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        table.registerForDraggedTypes([Coordinator.internalType, .fileURL])
        table.setDraggingSourceOperationMask([], forLocal: false)
        table.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
        table.setAccessibilityLabel(panel.side == .left ? "Lista plików, panel lewy" : "Lista plików, panel prawy")

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        context.coordinator.table = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.parent = self
        guard let table = c.table else { return }

        // Dane: przeładowanie tylko przy nowej tablicy wpisów (tożsamość bufora) lub zmianie trybu wyszukiwania.
        let identity = entries.withUnsafeBufferPointer { UnsafeRawPointer($0.baseAddress) }
        if identity != c.entriesIdentity || entries.count != c.entries.count || base != c.base {
            c.entries = entries
            c.entriesIdentity = identity
            c.base = base
            c.indexByID = nil
            c.updating { table.reloadData() }
            c.appliedSelection = nil
        }

        // Sortowanie: dokładnie jeden deskryptor zgodny ze stanem panelu (AppKit odtwarza też zapisane dodatkowe
        // deskryptory — wtedy klik w nagłówek dawałby nieoczekiwaną kolejność).
        let current = table.sortDescriptors
        if current.count != 1 || current[0].key != sortKey.rawValue || current[0].ascending != sortAscending {
            c.updating { table.sortDescriptors = [NSSortDescriptor(key: sortKey.rawValue, ascending: sortAscending)] }
        }

        // Zaznaczenie ze stanu panelu (np. po „Zaznacz wszystko”, nawigacji, menu).
        if c.appliedSelection != selection {
            let rows = c.rows(for: selection)
            if rows != table.selectedRowIndexes {
                c.updating { table.selectRowIndexes(rows, byExtendingSelection: false) }
                if let first = rows.first, selection.count == 1 { table.scrollRowToVisible(first) }
            }
            c.appliedSelection = selection
        }

        // Fokus klawiatury przechodzi na tabelę, gdy panel staje się aktywny (start, Tab, kliknięcie nagłówka panelu).
        // Gdy tabela nie jest jeszcze w oknie, fokus czeka na `viewDidMoveToWindow`.
        if isActive && !c.wasActive { c.focusPending = true }
        if !isActive { c.focusPending = false }
        c.wasActive = isActive
        c.applyPendingFocus()
    }

    // MARK: - Koordynator

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        struct ColumnSpec { let id: NSUserInterfaceItemIdentifier; let key: SortKey; let title: String; let min: CGFloat; let ideal: CGFloat; let max: CGFloat? }
        static let columns: [ColumnSpec] = [
            ColumnSpec(id: .init("name"), key: .name, title: "Nazwa", min: 90, ideal: 170, max: nil),
            ColumnSpec(id: .init("size"), key: .size, title: "Rozmiar", min: 50, ideal: 66, max: 120),
            ColumnSpec(id: .init("kind"), key: .kind, title: "Rodzaj", min: 50, ideal: 90, max: nil),
            ColumnSpec(id: .init("date"), key: .date, title: "Zmodyfikowano", min: 70, ideal: 110, max: nil),
        ]
        /// Przeciąganie wewnątrz aplikacji: adres elementu (także zdalny `ocremote://`).
        static let internalType = NSPasteboard.PasteboardType("org.opencommander.dragged-url")

        var parent: FileTableRepresentable
        weak var table: FileTableView?
        var entries: [FileEntry] = []
        var entriesIdentity: UnsafeRawPointer?
        var base: URL?
        var indexByID: [FileEntry.ID: Int]?
        var appliedSelection: Set<FileEntry.ID>?
        var wasActive = false
        var focusPending = false
        private var isUpdating = false

        init(_ parent: FileTableRepresentable) { self.parent = parent }

        func updating(_ body: () -> Void) { isUpdating = true; body(); isUpdating = false }

        func rows(for ids: Set<FileEntry.ID>) -> IndexSet {
            guard !ids.isEmpty else { return [] }
            if indexByID == nil {
                var map = [FileEntry.ID: Int](minimumCapacity: entries.count)
                for (i, e) in entries.enumerated() where map[e.id] == nil { map[e.id] = i }
                indexByID = map
            }
            return IndexSet(ids.compactMap { indexByID?[$0] })
        }

        func ids(for rows: IndexSet) -> Set<FileEntry.ID> {
            Set(rows.compactMap { $0 < entries.count ? entries[$0].id : nil })
        }

        /// Elementy, których dotyczy akcja na wierszu: całe zaznaczenie, jeśli wiersz do niego należy; inaczej ten wiersz.
        func targetIDs(row: Int) -> Set<FileEntry.ID> {
            guard row >= 0, row < entries.count, let table else { return [] }
            return table.selectedRowIndexes.contains(row) ? ids(for: table.selectedRowIndexes) : [entries[row].id]
        }

        // MARK: Dane i komórki

        func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, row < entries.count else { return nil }
            let entry = entries[row]
            switch tableColumn.identifier.rawValue {
            case "name":
                let cell = NameCellRow(entry: entry, base: base)
                if let view = tableView.makeView(withIdentifier: tableColumn.identifier, owner: nil) as? PassthroughHostingView<NameCellRow> {
                    view.rootView = cell
                    return view
                }
                let view = PassthroughHostingView(rootView: cell)
                view.sizingOptions = []
                view.identifier = tableColumn.identifier
                return view
            case "size":
                return textCell(tableView, tableColumn.identifier, entry.size.map { ProgressFormat.bytes($0) } ?? "—", alignment: .right, digits: true)
            case "kind":
                return textCell(tableView, tableColumn.identifier, entry.kind, alignment: .left, digits: false)
            default:
                return textCell(tableView, tableColumn.identifier, ModifiedDateText.string(for: entry.modificationDate), alignment: .left, digits: true)
            }
        }

        private func textCell(_ tableView: NSTableView, _ id: NSUserInterfaceItemIdentifier, _ text: String,
                              alignment: NSTextAlignment, digits: Bool) -> NSView {
            let cell: NSTableCellView
            if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView {
                cell = reused
            } else {
                cell = NSTableCellView()
                cell.identifier = id
                let field = NSTextField(labelWithString: "")
                field.translatesAutoresizingMaskIntoConstraints = false
                field.lineBreakMode = .byTruncatingTail
                field.textColor = .secondaryLabelColor
                let size = NSFont.systemFontSize
                field.font = digits ? .monospacedDigitSystemFont(ofSize: size, weight: .regular) : .systemFont(ofSize: size)
                field.alignment = alignment
                cell.addSubview(field)
                cell.textField = field
                NSLayoutConstraint.activate([
                    field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                    field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
            }
            cell.textField?.stringValue = text
            return cell
        }

        func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
            row < entries.count ? entries[row].name : nil
        }

        // MARK: Zaznaczenie i sortowanie

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isUpdating, let table else { return }
            let ids = ids(for: table.selectedRowIndexes)
            appliedSelection = ids
            if parent.panel.selection != ids { parent.panel.selection = ids }
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !isUpdating, let d = tableView.sortDescriptors.first, let key = SortKey(rawValue: d.key ?? "") else { return }
            parent.panel.setSort(key: key, ascending: d.ascending)
        }

        // MARK: Akcje

        @objc func doubleClicked(_ sender: Any?) {
            guard let table, table.clickedRow >= 0 else { return }
            open(targetIDs(row: table.clickedRow))
        }

        func open(_ ids: Set<FileEntry.ID>) {
            guard !ids.isEmpty else { return }
            parent.state.active = parent.panel.side
            parent.state.open(entries.filter { ids.contains($0.id) }, in: parent.panel)
        }

        func openSelection() { open(parent.panel.selection) }

        func toggleQuickLook() {
            guard !parent.panel.isRemote else { return }
            if parent.quickLookURL != nil { parent.quickLookURL = nil; return }
            parent.quickLookURL = parent.panel.selectedEntries.first?.url
        }

        /// Nie zabieramy fokusu polu tekstowemu (filtr, edycja ścieżki).
        func applyPendingFocus() {
            guard focusPending, let table, let window = table.window else { return }
            focusPending = false
            if window.firstResponder !== table, !(window.firstResponder is NSText) { window.makeFirstResponder(table) }
        }

        /// Kliknięcie w tabelę (lewym lub prawym) aktywuje jej panel. Fokus nadany tabeli przez okno przy starcie — nie.
        func userClicked() {
            let side = parent.panel.side
            if parent.state.active != side { parent.state.active = side }
        }

        func contextMenu(row: Int) -> NSMenu {
            let ids = targetIDs(row: row)
            return NSHostingMenu(rootView: PanelContextMenu(panel: parent.panel, state: parent.state, ids: ids,
                                                            quickLookURL: parent.$quickLookURL))
        }

        // MARK: Menu nagłówka (widoczność kolumn)

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table else { return }
            for spec in Self.columns where spec.key != .name {
                guard let column = table.tableColumn(withIdentifier: spec.id) else { continue }
                let item = NSMenuItem(title: spec.title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = spec.id.rawValue
                item.state = column.isHidden ? .off : .on
                menu.addItem(item)
            }
        }

        @objc func toggleColumn(_ item: NSMenuItem) {
            guard let raw = item.representedObject as? String,
                  let column = table?.tableColumn(withIdentifier: .init(raw)) else { return }
            column.isHidden.toggle()
        }

        // MARK: Przeciąganie

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard row < entries.count else { return nil }
            let item = NSPasteboardItem()
            item.setString(entries[row].url.absoluteString, forType: Self.internalType)
            return item
        }

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                       proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            // Upuszczenie dotyczy bieżącego folderu panelu (nie folderu pod kursorem) — jak dotąd.
            tableView.setDropRow(-1, dropOperation: .on)
            return .copy
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                       dropOperation: NSTableView.DropOperation) -> Bool {
            let pasteboard = info.draggingPasteboard
            var urls: [URL] = (pasteboard.pasteboardItems ?? []).compactMap { item in
                item.string(forType: Self.internalType).flatMap(URL.init(string:))
            }
            if urls.isEmpty {
                let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
                urls = (files ?? []).filter(\.isFileURL)
            }
            guard !urls.isEmpty else { return false }
            parent.state.handleDrop(urls, onto: parent.panel, optionHeld: NSEvent.modifierFlags.contains(.option))
            return true
        }
    }
}

/// Komórka SwiftUI, która nie przechwytuje myszy: kliknięcia (zaznaczanie, dwuklik, przeciąganie) obsługuje tabela.
private final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// `NSTableView` z obsługą klawiszy panelu, menu kontekstowego i informowaniem o fokusie.
@available(macOS 15.0, *)
final class FileTableView: NSTableView {
    fileprivate weak var coordinator: FileTableRepresentable.Coordinator?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in self?.coordinator?.applyPendingFocus() }
    }

    override func mouseDown(with event: NSEvent) {
        coordinator?.userClicked()
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        coordinator?.userClicked()
        super.rightMouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        _ = super.menu(for: event) // ustawia `clickedRow` (podświetlenie klikniętego wiersza)
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        return coordinator?.contextMenu(row: row)
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let plain = flags.subtracting([.numericPad, .function]).isEmpty
        switch event.keyCode {
        case 48 where plain: // Tab — przełączenie panelu
            coordinator?.parent.state.switchPanel()
            return
        case 36 where plain, 76 where plain: // Return / Enter — otwórz zaznaczone
            if !(coordinator?.parent.panel.selection.isEmpty ?? true) { coordinator?.openSelection(); return }
        case 49 where plain: // Spacja — szybki podgląd
            coordinator?.toggleQuickLook()
            return
        default:
            break
        }
        if flags == .option, let ch = event.charactersIgnoringModifiers?.lowercased() {
            if ch == "c" { coordinator?.parent.state.copyFilesToClipboard(); return }
            if ch == "v" { coordinator?.parent.state.pasteFilesFromClipboard(); return }
        }
        super.keyDown(with: event)
    }
}
