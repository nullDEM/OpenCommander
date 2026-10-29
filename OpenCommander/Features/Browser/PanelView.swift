import SwiftUI
import QuickLook
import AppKit
import CoreTransferable
import UniformTypeIdentifiers
import OpenCommanderCore

struct PanelView: View {
    @Bindable var panel: PanelState
    let tabs: PanelTabs
    let state: AppState
    var focus: FocusState<PanelSide?>.Binding

    @State private var showFilter = false
    /// Widoczność kolumn (prawy klik na nagłówku tabeli); zapamiętywana przez system.
    @SceneStorage("OpenCommander.columns.v2") private var columns: TableColumnCustomization<FileEntry>
    @State private var quickLookURL: URL?
    @FocusState private var filterFocused: Bool

    private var isActive: Bool { state.active == panel.side }

    var body: some View {
        VStack(spacing: 0) {
            if tabs.tabs.count > 1 { TabBar(tabs: tabs, state: state); Divider() }
            header
            Divider()
            if showFilter || panel.isFiltering { filterBar }
            if let error = panel.loadError { errorBanner(error) }
            table
            statusBar
        }
        .background(.background)
        // Wyraźny wskaźnik aktywnego panelu: pas w kolorze akcentu nad nagłówkiem.
        .overlay(alignment: .top) {
            Rectangle().fill(isActive ? Color.accentColor : Color.clear).frame(height: 3)
        }
        .animation(.easeInOut(duration: 0.12), value: isActive)
        .simultaneousGesture(TapGesture().onEnded { state.active = panel.side })
        .accessibilityElement(children: .contain)
        .accessibilityLabel(panel.side == .left ? "Panel lewy" : "Panel prawy")
        .accessibilityValue(isActive ? "aktywny" : "")
        .onChange(of: state.filterFocusToken) { _, _ in
            guard isActive else { return }
            showFilter = true
            filterFocused = true
        }
    }

    // MARK: Filtr bieżącego folderu (nie jest to wyszukiwanie rekurencyjne)

    private var filterBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease.circle").foregroundStyle(.secondary)
            TextField(panel.searchSubfolders ? "Szukaj w tym folderze i podfolderach" : "Filtruj ten folder", text: $panel.filterText)
                .textFieldStyle(.plain)
                .focused($filterFocused)
                .onKeyPress(.escape) { closeFilter(); return .handled }
                .onSubmit { focus.wrappedValue = panel.side }
                .accessibilityLabel("Wyszukiwanie nazw w bieżącym folderze")
            if panel.isSearching { ProgressView().controlSize(.small) }
            if panel.isFiltering {
                Text(panel.isRecursiveSearch
                     ? "\(panel.visibleEntries.count)\(panel.searchTruncated ? "+" : "") wyników"
                     : "\(panel.visibleEntries.count) z \(panel.entries.count)")
                    .font(.caption).foregroundStyle(.secondary)
                    .help(panel.searchTruncated ? "Pokazano pierwsze wyniki — zawęź zapytanie" : "")
            }
            Toggle(isOn: $panel.searchSubfolders) { Image(systemName: "folder.badge.gearshape") }
                .toggleStyle(.button).buttonStyle(.borderless)
                .help("Szukaj także w podfolderach").accessibilityLabel("Szukaj w podfolderach")
            Button { closeFilter() } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
                .help("Zamknij filtr (Esc)").accessibilityLabel("Zamknij filtr")
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Color.primary.opacity(0.05))
    }

    private func closeFilter() {
        panel.filterText = ""
        showFilter = false
        filterFocused = false
        focus.wrappedValue = panel.side
    }

    // MARK: Nagłówek: nawigacja + okruszki

    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                Button { panel.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!panel.canGoBack).help("Wstecz (⌘[)").accessibilityLabel("Wstecz")
                Button { panel.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!panel.canGoForward).help("Dalej (⌘])").accessibilityLabel("Dalej")
                Button { panel.goUp() } label: { Image(systemName: "arrow.up") }
                    .disabled(!panel.canGoUp).help("Folder nadrzędny (⌘↑)").accessibilityLabel("Folder nadrzędny")
            }
            BreadcrumbBar(url: panel.location, serverName: state.serverName(of: panel.location), onSelect: { panel.navigate(to: $0) })
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(isActive ? 0.09 : 0.05)))
            if panel.isLoading { ProgressView().controlSize(.small).accessibilityLabel("Ładowanie") }
            Button { state.active = panel.side; state.chooseFolder() } label: { Image(systemName: "folder") }
                .help("Wybierz folder… (⇧⌘O)").accessibilityLabel("Wybierz folder")
            Button { state.active = panel.side; state.newTab() } label: { Image(systemName: "plus.square.on.square") }
                .help("Nowa karta (⌘T)").accessibilityLabel("Nowa karta")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10).padding(.top, 9).padding(.bottom, 6)
        // Sygnał aktywności niezależny od koloru akcentu (bywa grafitowy): nieaktywny nagłówek jest przygaszony.
        .opacity(isActive ? 1 : 0.6)
        .background(isActive ? Color.accentColor.opacity(0.12) : Color.clear)
    }

    private func errorBanner(_ error: OperationError) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(error.localizedDescription).font(.callout).lineLimit(2)
            Spacer()
            Button("Ponów") { panel.reload() }
        }
        .padding(8)
        .background(Color.orange.opacity(0.12))
    }

    // MARK: Tabela

    private var sortBinding: Binding<[KeyPathComparator<FileEntry>]> {
        Binding(
            get: {
                let order: SortOrder = panel.sortAscending ? .forward : .reverse
                switch panel.sortKey {
                case .name: return [KeyPathComparator(\FileEntry.name, order: order)]
                case .size: return [KeyPathComparator(\FileEntry.sortSize, order: order)]
                case .kind: return [KeyPathComparator(\FileEntry.kind, order: order)]
                case .date: return [KeyPathComparator(\FileEntry.sortDate, order: order)]
                }
            },
            set: { new in
                guard let first = new.first else { return }
                let key: SortKey
                if first.keyPath == \FileEntry.sortSize { key = .size }
                else if first.keyPath == \FileEntry.kind { key = .kind }
                else if first.keyPath == \FileEntry.sortDate { key = .date }
                else { key = .name }
                panel.setSort(key: key, ascending: first.order == .forward)
            }
        )
    }

    private var table: some View {
        Table(of: FileEntry.self, selection: $panel.selection, sortOrder: sortBinding, columnCustomization: $columns) {
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
                Text(Self.dateText(entry.modificationDate))
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
            state.handleDrop(items.flatMap(\.urls), onto: panel, optionHeld: NSEvent.modifierFlags.contains(.option))
            return !items.isEmpty
        }
        .dropDestination(for: URL.self) { urls, _ in
            state.handleDrop(urls.filter(\.isFileURL), onto: panel, optionHeld: NSEvent.modifierFlags.contains(.option))
            return !urls.isEmpty
        }
        .contextMenu(forSelectionType: FileEntry.ID.self) { ids in
            contextMenu(for: ids)
        } primaryAction: { ids in
            state.active = panel.side
            state.open(panel.visibleEntries.filter { ids.contains($0.id) }, in: panel)
        }
        .quickLookPreview($quickLookURL, in: panel.isRemote ? [] : panel.selectedEntries.map(\.url))
        .alternatingRowBackgrounds(.disabled)
        .focused(focus, equals: panel.side)
        .onKeyPress(phases: .down) { press in
            // ⌥C / ⌥V jako dodatkowe skróty kopiowania i wklejania plików (⌥ zmienia znak na ç / √).
            guard press.modifiers == .option else { return .ignored }
            let ch = press.characters.lowercased()
            if ch == "c" || ch == "ç" { state.copyFilesToClipboard(); return .handled }
            if ch == "v" || ch == "√" { state.pasteFilesFromClipboard(); return .handled }
            return .ignored
        }
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
        .overlay {
            if panel.visibleEntries.isEmpty && !panel.isLoading && !panel.isSearching && panel.loadError == nil {
                VStack(spacing: 6) {
                    Image(systemName: panel.isFiltering ? "magnifyingglass" : "tray")
                        .font(.system(size: 28)).foregroundStyle(.tertiary)
                    Text(panel.isFiltering ? "Brak wyników dla „\(panel.filterText)”"
                         : (panel.showHidden ? "Folder jest pusty" : "Brak widocznych elementów"))
                        .foregroundStyle(.secondary)
                }
                .allowsHitTesting(false)
            }
        }
    }

    /// Przeciągany jest cały zaznaczony zbiór, jeśli chwycony wiersz do niego należy; inaczej tylko ten wiersz.
    private func draggedFiles(for entry: FileEntry) -> DraggedFiles {
        let items = panel.selection.contains(entry.id) ? panel.selectedEntries : [entry]
        return DraggedFiles(urls: items.map(\.url))
    }

    // MARK: Menu kontekstowe

    @ViewBuilder
    private func contextMenu(for ids: Set<FileEntry.ID>) -> some View {
        let entries = panel.visibleEntries.filter { ids.contains($0.id) }
        if entries.isEmpty {
            Button("Nowy folder") { state.active = panel.side; state.requestNewFolder() }
            Button("Odśwież") { panel.reload() }
            Button(state.showHidden ? "Ukryj pliki ukryte" : "Pokaż pliki ukryte") { state.setShowHidden(!state.showHidden) }
        } else {
            Button("Otwórz") { state.select(ids, in: panel); state.open(entries, in: panel) }
            if !panel.isRemote, entries.count == 1, !entries[0].isNavigable {
                let apps = state.applications(toOpen: entries[0].url)
                if !apps.isEmpty {
                    Menu("Otwórz za pomocą") {
                        ForEach(Array(apps.prefix(20)), id: \.self) { app in
                            Button(FileManager.default.displayName(atPath: app.path)) { state.open(entries[0].url, with: app) }
                        }
                    }
                }
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
            Button(panel.isRemote ? "Pobierz do drugiego panelu" : (state.panel(panel.side.other).isRemote ? "Wyślij na serwer (drugi panel)" : "Kopiuj do drugiego panelu")) { state.select(ids, in: panel); state.transferSelection(.copy) }
                .disabled(!state.canCopy)
            Button("Przenieś do drugiego panelu") { state.select(ids, in: panel); state.transferSelection(.move) }
                .disabled(state.anyPanelRemote || panel.location == state.panel(panel.side.other).location)
            if entries.count == 1 { Button("Zmień nazwę…") { state.select(ids, in: panel); state.requestRename() } }
            Divider()
            Button(panel.isRemote ? "Usuń z serwera…" : "Przenieś do Kosza", role: .destructive) { state.select(ids, in: panel); state.requestTrash() }
        }
    }

    // MARK: Pasek stanu

    private var statusBar: some View {
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
        var s = "Zaznaczono \(panel.selectedEntries.count) z \(total)"
        if panel.knownSelectedSize > 0 || panel.selectedWithUnknownSize == 0 {
            s += " · \(ProgressFormat.bytes(panel.knownSelectedSize))"
        }
        if panel.selectedWithUnknownSize > 0 { s += " (rozmiary folderów nie są liczone)" }
        return s
    }

    /// Zwięzły zapis daty: dziś / wczoraj z godziną, w tym roku „14 paź, 03:12”, wcześniej „1 mar 2025”.
    static func dateText(_ date: Date?) -> String {
        guard let date else { return "—" }
        let cal = Calendar.current
        let time = date.formatted(.dateTime.hour().minute())
        if cal.isDateInToday(date) { return "Dziś, \(time)" }
        if cal.isDateInYesterday(date) { return "Wczoraj, \(time)" }
        if cal.isDate(date, equalTo: Date(), toGranularity: .year) {
            return date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
        }
        return date.formatted(.dateTime.day().month(.abbreviated).year())
    }
}

private struct NameCell: View {
    let entry: FileEntry
    /// W wynikach wyszukiwania w podfolderach: folder, względem którego pokazujemy ścieżkę wyniku.
    var base: URL?
    /// Własna ikona pakietu (np. programu); do czasu załadowania widać ikonę typu.
    @State private var packageIcon: NSImage?

    private var relativeFolder: String? {
        guard let base else { return nil }
        let parent = entry.url.deletingLastPathComponent().path
        guard parent != base.path, parent.hasPrefix(base.path + "/") else { return nil }
        return String(parent.dropFirst(base.path.count + 1))
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: packageIcon ?? IconCache.typeIcon(for: entry)).resizable().frame(width: 16, height: 16)
            Text(entry.name).italic(entry.isSymbolicLink).lineLimit(1).truncationMode(.middle)
            if let sub = relativeFolder {
                Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            if entry.isSymbolicLink {
                Image(systemName: "arrow.turn.up.right").font(.caption).foregroundStyle(.secondary)
                    .help("Dowiązanie symboliczne")
            }
        }
        .opacity(entry.isHidden ? 0.6 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(entry.isSymbolicLink ? "\(entry.name), dowiązanie symboliczne" : entry.name)
        .task(id: entry.id) {
            guard entry.isPackage else { packageIcon = nil; return }
            packageIcon = await IconCache.packageIcon(at: entry.url)
        }
    }
}

/// Ikony: pliki i foldery — według typu (jedna ikona na typ, tanio); pakiety `.app` — według ścieżki,
/// bo każdy program ma własną ikonę, a wszystkie mają ten sam typ.
enum IconCache {
    @MainActor private static var typeCache: [String: NSImage] = [:]
    private static let packageCache = NSCache<NSString, NSImage>()

    @MainActor
    static func typeIcon(for entry: FileEntry) -> NSImage {
        let key = entry.isNavigable ? "folder" : (entry.contentType?.identifier ?? "public.data")
        if let hit = typeCache[key] { return hit }
        let image = entry.isNavigable
            ? NSWorkspace.shared.icon(for: .folder)
            : NSWorkspace.shared.icon(for: entry.contentType ?? .data)
        typeCache[key] = image
        return image
    }

    /// Ładuje ikonę poza głównym wątkiem; wynik jest buforowany po ścieżce.
    static func packageIcon(at url: URL) async -> NSImage {
        let key = url.path as NSString
        if let hit = packageCache.object(forKey: key) { return hit }
        let image = await Task.detached(priority: .utility) { NSWorkspace.shared.icon(forFile: url.path) }.value
        packageCache.setObject(image, forKey: key)
        return image
    }
}

/// Klikalne okruszki ścieżki (dla woluminów zewnętrznych korzeniem jest sam wolumin).
struct BreadcrumbBar: View {
    let url: URL
    var serverName: String?
    let onSelect: (URL) -> Void

    private var items: [Breadcrumb] {
        guard let r = url.remoteLocation else { return Breadcrumbs.items(for: url) }
        // Serwer zdalny: korzeń to nazwa połączenia, dalej składowe ścieżki zdalnej.
        var out = [Breadcrumb(title: serverName ?? "Serwer", url: RemoteLocation(connectionID: r.connectionID, path: .root).url)]
        var path = RemotePath.root
        for c in r.path.components {
            path = (try? path.appending(c)) ?? path
            out.append(Breadcrumb(title: c, url: RemoteLocation(connectionID: r.connectionID, path: path).url))
        }
        return out
    }

    var body: some View {
        let items = self.items
        // Przewijany widok bez żadnego sprzężenia rozmiaru z kontenerem (GeometryReader + minWidth powodował
        // lawinę przeliczeń układu w podzielonym widoku). Krótka ścieżka stoi od lewej; długa jest przewijana
        // do końca jawnie — przy pojawieniu się, zmianie folderu i zmianie szerokości (pomiar tylko w tle).
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) { row(items) }
                .onAppear { scrollToEnd(proxy, items) }
                .onChange(of: url) { _, _ in scrollToEnd(proxy, items) }
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onChange(of: geo.size.width) { _, _ in scrollToEnd(proxy, items) }
                    }
                )
        }
        .frame(height: 18)
        .accessibilityLabel("Ścieżka: \(url.remoteLocation?.path.string ?? url.path)")
    }

    private static let endMarker = "breadcrumb-end"

    private func scrollToEnd(_ proxy: ScrollViewProxy, _ items: [Breadcrumb]) {
        guard !items.isEmpty else { return }
        // Pierwsze przewinięcie po bieżącym układzie, drugie — gdy szerokości segmentów są już ustalone.
        DispatchQueue.main.async { proxy.scrollTo(Self.endMarker, anchor: .trailing) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { proxy.scrollTo(Self.endMarker, anchor: .trailing) }
    }

    private func row(_ items: [Breadcrumb]) -> some View {
        HStack(spacing: 3) {
            ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                if idx > 0 { Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary) }
                Button { onSelect(item.url) } label: {
                    Text(item.title)
                        .fontWeight(idx == items.count - 1 ? .semibold : .regular)
                        .foregroundStyle(idx == items.count - 1 ? .primary : .secondary)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .help(item.url.remoteLocation?.path.string ?? item.url.path)
            }
            // Niewidoczny znacznik końca — cel przewijania (osobny identyfikator, bez kolizji z ForEach).
            Color.clear.frame(width: 1, height: 1).id(Self.endMarker)
        }
        .fixedSize()
    }
}


/// Ładunek przeciągania między panelami (lista adresów); nie opuszcza aplikacji.
struct DraggedFiles: Codable, Transferable {
    let urls: [URL]
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json)
    }
}
