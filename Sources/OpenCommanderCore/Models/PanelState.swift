import Foundation
import Observation

/// Stan jednego panelu: lokalizacja, historia, zaznaczenie, sortowanie, ładowanie i błąd.
@MainActor @Observable
public final class PanelState: Identifiable {
    public let id = UUID()
    public let side: PanelSide
    public private(set) var location: URL
    public private(set) var entries: [FileEntry] = []
    public var selection: Set<FileEntry.ID> = []
    /// Filtr nazwy bieżącego folderu. Czyszczony przy zmianie folderu.
    public var filterText = "" { didSet { if filterText != oldValue { pruneSelectionToVisible(); scheduleSearch() } } }
    /// Gdy włączone, filtr przeszukuje też podfoldery (rekurencyjnie), a nie tylko bieżącą listę.
    public var searchSubfolders = true { didSet { if searchSubfolders != oldValue { scheduleSearch(); pruneSelectionToVisible() } } }
    public private(set) var isSearching = false
    public private(set) var searchTruncated = false
    @ObservationIgnored private var searchResults: [FileEntry]?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    public private(set) var isLoading = false
    public private(set) var loadError: OperationError?
    public private(set) var sortKey: SortKey
    public private(set) var sortAscending: Bool
    public private(set) var showHidden: Bool
    /// Wolne miejsce na woluminie bieżącego folderu (`nil`, dopóki nieznane).
    public private(set) var freeSpace: Int64?
    public private(set) var back: [URL] = []
    public private(set) var forward: [URL] = []

    @ObservationIgnored public var onStateChange: (() -> Void)?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var watcher: DirectoryWatcher?
    @ObservationIgnored private var watchedPath: String?

    private enum HistoryMode { case push, back, forward, none }

    public init(side: PanelSide, location: URL, sortKey: SortKey = .name, sortAscending: Bool = true, showHidden: Bool = false) {
        self.side = side
        self.location = location.standardizedFileURL
        self.sortKey = sortKey
        self.sortAscending = sortAscending
        self.showHidden = showHidden
    }

    // MARK: - Pochodne

    public var canGoBack: Bool { !back.isEmpty }
    public var canGoForward: Bool { !forward.isEmpty }
    public var canGoUp: Bool { location.path != "/" }
    /// Wpisy widoczne po filtrze. Operacje działają wyłącznie na widocznych — nie na ukrytych filtrem.
    public var visibleEntries: [FileEntry] {
        if isRecursiveSearch, let results = searchResults { return FileFilter.apply(results, text: filterText) }
        return FileFilter.apply(entries, text: filterText)
    }
    /// Filtr działa na całym drzewie pod bieżącym folderem (wyniki mogą leżeć w podfolderach).
    public var isRecursiveSearch: Bool { searchSubfolders && isFiltering }
    public var isFiltering: Bool { !filterText.trimmingCharacters(in: .whitespaces).isEmpty }
    public var selectedEntries: [FileEntry] { visibleEntries.filter { selection.contains($0.id) } }
    /// Suma rozmiarów zaznaczonych plików, których rozmiar jest znany (foldery nie są liczone).
    public var knownSelectedSize: Int64 { selectedEntries.compactMap(\.size).reduce(0, +) }
    public var selectedWithUnknownSize: Int { selectedEntries.filter { $0.size == nil }.count }

    // MARK: - Nawigacja

    public func navigate(to url: URL) { load(url.standardizedFileURL, mode: .push, select: nil) }

    public func goBack() {
        guard let target = back.last else { return }
        load(target, mode: .back, select: nil)
    }

    public func goForward() {
        guard let target = forward.last else { return }
        load(target, mode: .forward, select: nil)
    }

    public func goUp() {
        guard canGoUp else { return }
        let child = location
        load(location.deletingLastPathComponent().standardizedFileURL, mode: .push, select: [child.path])
    }

    /// Odświeża bieżący folder. `select` — ścieżki do zaznaczenia po załadowaniu.
    public func reload(selecting select: [URL]? = nil) {
        load(location, mode: .none, select: select.map { Set($0.map { $0.standardizedFileURL.path }) })
    }

    public func setShowHidden(_ value: Bool) {
        guard value != showHidden else { return }
        showHidden = value
        reload()
    }

    public func setSort(key: SortKey, ascending: Bool) {
        sortKey = key
        sortAscending = ascending
        entries = FileSorter.sorted(entries, by: key, ascending: ascending)
        searchResults = searchResults.map { FileSorter.sorted($0, by: key, ascending: ascending) }
        onStateChange?()
    }

    /// Czeka na zakończenie bieżącego ładowania (testy).
    public func waitUntilIdle() async { await loadTask?.value }

    // MARK: - Ładowanie

    private func load(_ target: URL, mode: HistoryMode, select: Set<FileEntry.ID>?) {
        loadTask?.cancel()
        generation &+= 1
        let gen = generation
        isLoading = true
        let hidden = showHidden
        loadTask = Task { [weak self] in
            do {
                let list = try await DirectoryLister.list(target, showHidden: hidden)
                guard let self, gen == self.generation else { return } // nieaktualny wynik
                self.commit(target, list, mode, select)
            } catch is CancellationError {
                return
            } catch {
                guard let self, gen == self.generation else { return }
                self.isLoading = false
                self.loadError = OperationError.map(error, item: target.lastPathComponent)
            }
        }
    }

    private func pruneSelectionToVisible() {
        let visible = Set(visibleEntries.map(\.id))
        selection = selection.intersection(visible)
    }

    /// Automatyczne odświeżanie po zmianach w bieżącym folderze (dodanie/usunięcie/zmiana nazwy elementu).
    private func watchIfNeeded(_ url: URL) {
        guard watchedPath != url.path else { return }
        watcher?.stop()
        watchedPath = url.path
        watcher = DirectoryWatcher(url: url) { [weak self] in
            Task { @MainActor in self?.reloadIfIdle() }
        }
    }

    private func reloadIfIdle() {
        guard !isLoading else { return }
        reload()
    }

    private func refreshFreeSpace(for url: URL) {
        Task { [weak self] in
            let space = await Task.detached { Locations.freeSpace(at: url) }.value
            guard let self, self.location == url else { return }
            self.freeSpace = space
        }
    }

    private func commit(_ target: URL, _ list: [FileEntry], _ mode: HistoryMode, _ select: Set<FileEntry.ID>?) {
        let changed = target.path != location.path
        switch mode {
        case .push where changed:
            back.append(location); forward.removeAll()
        case .back:
            forward.append(location); back.removeLast()
        case .forward:
            back.append(location); forward.removeLast()
        default:
            break
        }
        location = target
        watchIfNeeded(target)
        if changed { filterText = "" }
        refreshFreeSpace(for: target)
        entries = FileSorter.sorted(list, by: sortKey, ascending: sortAscending)
        loadError = nil
        isLoading = false
        let ids = Set(entries.map(\.id))
        if let select {
            selection = select.intersection(ids)
        } else if changed {
            selection = []
        } else {
            selection = selection.intersection(ids)
        }
        if isRecursiveSearch && !changed { scheduleSearch() }
        onStateChange?()
    }

    /// Wyszukiwanie w podfolderach z krótkim opóźnieniem (pisanie nie uruchamia setek skanów).
    private func scheduleSearch() {
        searchTask?.cancel()
        guard isRecursiveSearch else {
            searchResults = nil; isSearching = false; searchTruncated = false
            return
        }
        let query = filterText, root = location, hidden = showHidden
        isSearching = true
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            do {
                let result = try await RecursiveSearch.search(root: root, query: query, showHidden: hidden)
                guard let self, !Task.isCancelled, self.location == root else { return }
                self.searchResults = FileSorter.sorted(result.entries, by: self.sortKey, ascending: self.sortAscending)
                self.searchTruncated = result.truncated
                self.isSearching = false
                self.pruneSelectionToVisible()
            } catch is CancellationError {
                return
            } catch {
                self?.isSearching = false
            }
        }
    }
}
