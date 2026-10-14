import AppKit
import Observation
import OpenCommanderCore

enum ActiveSheet: Identifiable {
    case newFolder
    case rename(FileEntry)
    case saveWorkspace
    case batchRename([FileEntry])
    case compareFolders
    case duplicates(URL)

    var id: String {
        switch self {
        case .saveWorkspace: return "saveWorkspace"
        case .batchRename: return "batchRename"
        case .compareFolders: return "compare"
        case .duplicates(let u): return "dups-\(u.path)"
        case .newFolder: return "newFolder"
        case .rename(let e): return "rename-\(e.id)"
        }
    }
}

@MainActor @Observable
final class AppState {
    let tabsLeft: PanelTabs
    let tabsRight: PanelTabs
    let operations: OperationCenter
    @ObservationIgnored private let journal = TempJournal.default

    var active: PanelSide = .left
    private(set) var showHidden: Bool
    var operationsExpanded: Bool { didSet { persist() } }
    var sheet: ActiveSheet?
    var pendingTrash: [FileEntry] = []
    var alertMessage: String?
    private(set) var volumes: [VolumeInfo] = Locations.mountedVolumes()
    /// Woluminy, które właśnie są wysuwane (spinner w pasku bocznym).
    private(set) var ejecting: Set<String> = []
    private(set) var workspaces: [Workspace]
    private(set) var favorites: [URL]
    private(set) var recents: [URL]
    var showInspector: Bool { didSet { persist() } }
    /// Zwiększany przez ⌘F — aktywny panel pokazuje i fokusuje pasek filtra.
    private(set) var filterFocusToken = 0
    @ObservationIgnored private var lastRecorded: [PanelSide: String] = [:]

    @ObservationIgnored private let store = SettingsStore()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        let s = store.load()
        operations = OperationCenter(journal: journal)
        showHidden = s.showHidden
        operationsExpanded = s.operationsExpanded
        favorites = s.favorites.map(Self.normalized)
        recents = s.recents.map(Self.normalized)
        showInspector = s.inspectorVisible
        active = s.activePanel
        workspaces = s.workspaces
        // Fabryka kart potrzebuje `self` (ukryte pliki, powiadomienia o zmianach), który nie jest jeszcze gotowy —
        // dlatego słaba referencja ustawiana na końcu inicjalizacji.
        let box = WeakBox<AppState>()
        let initialHidden = s.showHidden
        func factory(_ side: PanelSide) -> (PanelSettings) -> PanelState {
            { settings in
                let p = PanelState(side: side,
                                   location: Locations.nearestExistingDirectory(URL(fileURLWithPath: settings.path)),
                                   sortKey: settings.sortKey, sortAscending: settings.sortAscending,
                                   showHidden: box.value?.showHidden ?? initialHidden)
                p.onStateChange = { [weak box, weak p] in if let p, let state = box?.value { state.panelChanged(p) } }
                return p
            }
        }
        tabsLeft = PanelTabs(side: .left, settings: s.leftTabs.isEmpty ? [s.left] : s.leftTabs,
                             activeIndex: s.leftActiveTab, factory: factory(.left))
        tabsRight = PanelTabs(side: .right, settings: s.rightTabs.isEmpty ? [s.right] : s.rightTabs,
                              activeIndex: s.rightActiveTab, factory: factory(.right))
        box.value = self
        operations.onJobFinished = { [weak self] job in self?.jobFinished(job) }
        reportLeftovers(journal.sweep())

        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.volumes = Locations.mountedVolumes() }
            })
        }
    }

    /// Informuje o sprzątaniu po poprzedniej sesji (zamknięcie lub awaria w trakcie operacji).
    private func reportLeftovers(_ r: TempJournal.SweepResult) {
        guard !r.isEmpty else { return }
        var lines: [String] = ["Poprzednia sesja została przerwana w trakcie operacji na plikach."]
        if r.removed > 0 { lines.append("Usunięto niedokończone kopie tymczasowe: \(r.removed). Oryginały nie były ruszane.") }
        if r.restored > 0 { lines.append("Przywrócono elementy, które były w trakcie przenoszenia: \(r.restored).") }
        if !r.leftBehind.isEmpty {
            lines.append("Nie można było automatycznie przywrócić (pliki zostały na miejscu, nic nie skasowano):")
            lines += r.leftBehind
        }
        alertMessage = lines.joined(separator: "\n")
    }

    // MARK: - Pomocnicze

    func tabs(_ side: PanelSide) -> PanelTabs { side == .left ? tabsLeft : tabsRight }
    func panel(_ side: PanelSide) -> PanelState { tabs(side).active }
    var left: PanelState { tabsLeft.active }
    var right: PanelState { tabsRight.active }
    var allTabs: [PanelState] { tabsLeft.tabs + tabsRight.tabs }
    var activeTabs: PanelTabs { tabs(active) }
    var activePanel: PanelState { panel(active) }
    var otherPanel: PanelState { panel(active.other) }
    var isBusyWithDialog: Bool { sheet != nil || !pendingTrash.isEmpty || operations.pendingConflict != nil }

    func switchPanel() { active = active.other }

    func persist() {
        func ps(_ p: PanelState) -> PanelSettings {
            PanelSettings(path: p.location.path, sortKey: p.sortKey, sortAscending: p.sortAscending)
        }
        store.save(AppSettings(left: ps(left), right: ps(right), showHidden: showHidden,
                               activePanel: active, operationsExpanded: operationsExpanded,
                               favorites: favorites.map(\.path), recents: recents.map(\.path),
                               inspectorVisible: showInspector,
                               leftTabs: tabsLeft.snapshot, rightTabs: tabsRight.snapshot,
                               leftActiveTab: tabsLeft.activeIndex, rightActiveTab: tabsRight.activeIndex,
                               workspaces: workspaces))
    }

    // MARK: - Karty

    func newTab() { if activeTabs.addTab() == nil { alertMessage = "Osiągnięto limit \(PanelTabs.maxTabs) kart w panelu." }; persist() }

    func openInNewTab(_ url: URL) {
        let p = activePanel
        if activeTabs.addTab(from: PanelSettings(path: url.path, sortKey: p.sortKey, sortAscending: p.sortAscending)) == nil {
            alertMessage = "Osiągnięto limit \(PanelTabs.maxTabs) kart w panelu."
        }
        persist()
    }

    func selectTab(_ side: PanelSide, _ index: Int) { active = side; tabs(side).select(index); persist() }
    func closeTab(_ side: PanelSide, _ index: Int) { tabs(side).closeTab(at: index); persist() }
    func nextTab() { activeTabs.selectNext(); persist() }
    func previousTab() { activeTabs.selectPrevious(); persist() }

    /// ⌘W: zamyka kartę; gdy to ostatnia karta panelu — zamyka okno (jak w innych aplikacjach z kartami).
    func closeActiveTabOrWindow() {
        if activeTabs.tabs.count > 1 { closeTab(active, activeTabs.activeIndex) } else { NSApp.keyWindow?.performClose(nil) }
    }

    func closeOtherTabs(_ side: PanelSide, keeping index: Int) {
        let t = tabs(side)
        guard t.tabs.indices.contains(index) else { return }
        let keep = t.tabs[index].id
        while let i = t.tabs.firstIndex(where: { $0.id != keep }) { t.closeTab(at: i) }
        persist()
    }

    func tabTitle(_ p: PanelState) -> String {
        p.location.path == "/" ? Locations.rootVolumeName() : p.location.lastPathComponent
    }

    // MARK: - Przestrzenie robocze

    func requestSaveWorkspace() { sheet = .saveWorkspace }

    /// Zwraca komunikat błędu albo `nil`. Nie nadpisuje istniejącej przestrzeni o tej samej nazwie.
    func saveWorkspace(named name: String) -> String? {
        do { try Workspaces.validate(name: name, in: workspaces) } catch { return error.localizedDescription }
        workspaces.append(Workspace(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                    left: tabsLeft.snapshot, leftActive: tabsLeft.activeIndex,
                                    right: tabsRight.snapshot, rightActive: tabsRight.activeIndex, activePanel: active))
        persist()
        return nil
    }

    func applyWorkspace(_ w: Workspace) {
        tabsLeft.replaceAll(with: w.left, activeIndex: w.leftActive)
        tabsRight.replaceAll(with: w.right, activeIndex: w.rightActive)
        active = w.activePanel
        persist()
    }

    func deleteWorkspace(_ w: Workspace) { workspaces.removeAll { $0.id == w.id }; persist() }

    /// Zapamiętuje ostatnie lokalizacje (tylko faktyczne zmiany folderu) i zapisuje ustawienia.
    private func panelChanged(_ panel: PanelState) {
        let path = panel.location.path
        if lastRecorded[panel.side] != path {
            lastRecorded[panel.side] = path
            recents = LocationHistory.promoting(path, in: recents.map(\.path)).map(Self.normalized)
        }
        persist()
    }

    // MARK: - Ulubione

    /// Jedna postać ścieżki (np. `/private/tmp` → `/tmp`), żeby ta sama lokalizacja nie dublowała się na listach.
    private static func normalized(_ path: String) -> URL { URL(fileURLWithPath: path).standardizedFileURL }

    func isFavorite(_ url: URL) -> Bool { favorites.contains { $0.path == url.standardizedFileURL.path } }

    func addFavorite(_ url: URL) {
        guard !isFavorite(url) else { return }
        favorites.append(url.standardizedFileURL); persist()
    }

    func removeFavorite(_ url: URL) {
        let path = url.standardizedFileURL.path
        favorites.removeAll { $0.path == path }; persist()
    }

    func toggleFavoriteForActivePanel() {
        let url = activePanel.location
        if isFavorite(url) { removeFavorite(url) } else { addFavorite(url) }
    }

    func requestFilter() { filterFocusToken += 1 }

    // MARK: - Menu kontekstowe

    /// Akcje z menu kontekstowego działają na klikniętych elementach: jeśli prawy klik trafił poza zaznaczenie,
    /// zaznaczenie zamienia się na ten element (jak w Finderze).
    func select(_ ids: Set<FileEntry.ID>, in panel: PanelState) {
        active = panel.side
        if !ids.isEmpty && !ids.isSubset(of: panel.selection) { panel.selection = ids }
    }

    func applications(toOpen url: URL) -> [URL] { NSWorkspace.shared.urlsForApplications(toOpen: url) }

    func open(_ url: URL, with app: URL) {
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    func setShowHidden(_ value: Bool) {
        showHidden = value
        for tab in allTabs { tab.setShowHidden(value) }
        persist()
    }

    func refreshAll() { left.reload(); right.reload(); volumes = Locations.mountedVolumes() } // karty w tle odświeżają się przy wyborze

    private func jobFinished(_ job: OperationCenter.Job) {
        refreshAll()
        // Błędy mają być widoczne bez szukania — rozwiń obszar operacji.
        if job.state == .failed || job.state == .completedWithIssues { operationsExpanded = true }
    }

    // MARK: - Nawigacja

    func open(_ entries: [FileEntry], in panel: PanelState) {
        if entries.count == 1, let e = entries.first, e.isNavigable {
            panel.navigate(to: e.url)
            return
        }
        for e in entries where !e.isNavigable { NSWorkspace.shared.open(e.url) }
    }

    func openSelection() {
        let p = activePanel
        open(p.selectedEntries, in: p)
    }

    func chooseFolder() {
        let p = activePanel
        let dialog = NSOpenPanel()
        dialog.canChooseDirectories = true
        dialog.canChooseFiles = false
        dialog.allowsMultipleSelection = false
        dialog.directoryURL = p.location
        dialog.prompt = "Wybierz"
        dialog.message = "Wybierz folder do wyświetlenia w panelu"
        if dialog.runModal() == .OK, let url = dialog.url { p.navigate(to: url) }
    }

    func revealInFinder() {
        let urls = activePanel.selectedEntries.map(\.url)
        if urls.isEmpty { NSWorkspace.shared.open(activePanel.location) } else { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    /// Schowek plików: zapisuje zaznaczone elementy jako adresy plików (Finder też je wklei).
    func copyFilesToClipboard() {
        let urls = activePanel.selectedEntries.map(\.url)
        guard !urls.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(urls as [NSURL])
    }

    var canPasteFiles: Bool {
        NSPasteboard.general.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    /// Wkleja (kopiuje) pliki ze schowka do folderu aktywnego panelu. Nic nie jest nadpisywane — konflikty obsługuje silnik.
    func pasteFilesFromClipboard() {
        let urls = (NSPasteboard.general.readObjects(forClasses: [NSURL.self],
                                                     options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty else { return }
        operations.enqueue(FileOperation(kind: .copy, sources: urls, destination: activePanel.location))
        operationsExpanded = true
    }

    /// Gdy pole tekstowe (np. filtr) ma fokus, ⌘C/⌘V działają na tekst, nie na pliki.
    var textFieldHasFocus: Bool { NSApp.keyWindow?.firstResponder is NSText }

    func copyPathToPasteboard() {
        let paths = activePanel.selectedEntries.map(\.url.path)
        let text = paths.isEmpty ? activePanel.location.path : paths.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Wysuwanie

    /// Wolumin wysuwalny, na którym leży folder aktywnego panelu.
    var ejectableVolumeOfActivePanel: VolumeInfo? {
        VolumeEjector.volume(containing: activePanel.location, in: volumes).flatMap { $0.canEject ? $0 : nil }
    }

    func ejectActivePanelVolume() {
        if let v = ejectableVolumeOfActivePanel { eject(v) }
    }

    func eject(_ volume: VolumeInfo) {
        guard volume.canEject, !ejecting.contains(volume.id) else { return }
        // Nie wysuwamy woluminu, na którym pracuje kolejka operacji.
        let busy = operations.jobs.contains { job in
            guard !job.state.isFinished else { return false }
            let paths = job.operation.sources.map(\.path) + (job.operation.destination.map { [$0.path] } ?? [])
            return paths.contains { VolumeEjector.isInside($0, volume: volume.url.path) }
        }
        if busy {
            alertMessage = "Na woluminie „\(volume.name)” trwa operacja z kolejki. Poczekaj na jej zakończenie albo ją anuluj, a potem wysuń wolumin."
            return
        }
        ejecting.insert(volume.id)
        Task {
            do {
                try await VolumeEjector.eject(volume)
                // Panele pokazujące wysunięty wolumin wracają do katalogu domowego.
                for panel in allTabs where VolumeEjector.isInside(panel.location.path, volume: volume.url.path) {
                    panel.navigate(to: Locations.home)
                }
            } catch {
                alertMessage = error.localizedDescription
            }
            ejecting.remove(volume.id)
            volumes = Locations.mountedVolumes()
        }
    }

    // MARK: - Operacje

    /// Kopiowanie do tego samego folderu jest dozwolone (powstaje „… kopia”); przeniesienie — nie ma sensu.
    var canCopy: Bool { !activePanel.selection.isEmpty }
    var canMove: Bool { !activePanel.selection.isEmpty && activePanel.location != otherPanel.location }

    func transferSelection(_ kind: OperationKind) {
        let sources = activePanel.selectedEntries.map(\.url)
        guard !sources.isEmpty, kind == .copy || canMove else { return }
        operations.enqueue(FileOperation(kind: kind, sources: sources, destination: otherPanel.location))
        operationsExpanded = true
    }

    /// Upuszczenie elementów na panel (z drugiego panelu lub z Findera). Nic nie jest nadpisywane — konflikty obsługuje silnik.
    func handleDrop(_ urls: [URL], onto panel: PanelState, optionHeld: Bool) {
        let sources = DropPlanner.effectiveSources(urls, destination: panel.location)
        guard !sources.isEmpty else { return }
        let kind = DropPlanner.kind(sources: sources, destination: panel.location, optionHeld: optionHeld)
        operations.enqueue(FileOperation(kind: kind, sources: sources, destination: panel.location))
        operationsExpanded = true
    }

    func requestTrash() {
        let entries = activePanel.selectedEntries
        if !entries.isEmpty { pendingTrash = entries }
    }

    func confirmTrash() {
        let urls = pendingTrash.map(\.url)
        pendingTrash = []
        guard !urls.isEmpty else { return }
        operations.enqueue(FileOperation(kind: .trash, sources: urls))
        operationsExpanded = true
    }

    func requestNewFolder() { sheet = .newFolder }

    // MARK: - Narzędzia (etap 3)

    func requestBatchRename() {
        let entries = activePanel.selectedEntries
        if !entries.isEmpty { sheet = .batchRename(entries) }
    }
    func requestCompare() { sheet = .compareFolders }
    func requestDuplicates() { sheet = .duplicates(activePanel.location) }

    func applyBatchRename(_ items: [BatchRenameItem]) async -> BatchRename.Outcome {
        let panel = activePanel
        let journal = self.journal
        let outcome = await Task.detached { BatchRename.apply(items, journal: journal) }.value
        panel.reload(selecting: outcome.newURLs)
        return outcome
    }

    /// Kopiuje pozycje porównania; pozycje grupowane są według folderu nadrzędnego, więc zachowują strukturę.
    func copyDifferences(_ items: [ComparisonItem], from: URL, to: URL) {
        let grouped = Dictionary(grouping: items) { ($0.relativePath as NSString).deletingLastPathComponent }
        for (parent, group) in grouped.sorted(by: { $0.key < $1.key }) {
            let sources = group.map { from.appendingPathComponent($0.relativePath) }
            let dest = parent.isEmpty ? to : to.appendingPathComponent(parent)
            operations.enqueue(FileOperation(kind: .copy, sources: sources, destination: dest))
        }
        operationsExpanded = true
    }

    func trashURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        operations.enqueue(FileOperation(kind: .trash, sources: urls))
        operationsExpanded = true
    }

    func requestRename() {
        if activePanel.selectedEntries.count == 1, let e = activePanel.selectedEntries.first { sheet = .rename(e) }
    }

    /// Zwraca komunikat błędu albo `nil` po sukcesie.
    func createFolder(named name: String) async -> String? {
        let panel = activePanel
        let parent = panel.location
        do {
            let url = try await Task.detached { try FileService.createFolder(named: name, in: parent) }.value
            panel.reload(selecting: [url])
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func rename(_ entry: FileEntry, to name: String) async -> String? {
        let panel = activePanel
        do {
            let journal = self.journal
            let url = try await Task.detached { try FileService.rename(entry.url, to: name, journal: journal) }.value
            panel.reload(selecting: [url])
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

/// Słaba referencja w pudełku — pozwala fabryce kart sięgnąć do `AppState` po zakończeniu jego inicjalizacji.
final class WeakBox<T: AnyObject> {
    weak var value: T?
}
