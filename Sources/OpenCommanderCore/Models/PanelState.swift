import Foundation
import Observation

/// Stan jednego panelu: lokalizacja, historia, zaznaczenie, sortowanie, ładowanie i błąd.
@MainActor @Observable
public final class PanelState: Identifiable {
    public let id = UUID()
    public let side: PanelSide
    public private(set) var location: URL
    public private(set) var entries: [FileEntry] = []
    /// Wpisy widoczne po filtrze. Liczone przy zmianie listy, filtra lub wyników wyszukiwania (nie przy każdym odczycie).
    /// Operacje działają wyłącznie na widocznych — nie na ukrytych filtrem.
    public private(set) var visibleEntries: [FileEntry] = []
    public var selection: Set<FileEntry.ID> = []
    /// Filtr nazwy bieżącego folderu. Czyszczony przy zmianie folderu.
    public var filterText = "" { didSet { if filterText != oldValue { recomputeVisible(); pruneSelectionToVisible(); scheduleSearch() } } }
    /// Gdy włączone, filtr przeszukuje też podfoldery (rekurencyjnie), a nie tylko bieżącą listę.
    public var searchSubfolders = true { didSet { if searchSubfolders != oldValue { scheduleSearch(); recomputeVisible(); pruneSelectionToVisible() } } }
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
    /// Listowanie lokalizacji zdalnych (`ocremote://…`); ustawiane przez aplikację. Bez niego zdalny adres kończy się błędem.
    @ObservationIgnored public var remoteLister: (@Sendable (RemoteLocation) async throws -> [FileEntry])?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var sortTask: Task<Void, Never>?
    /// Zwiększane przy każdej zmianie kolejności i przy każdym załadowaniu — nieaktualne sortowanie w tle jest wtedy odrzucane.
    @ObservationIgnored private var sortGeneration = 0
    @ObservationIgnored private var lastWatcherReload = Date.distantPast
    @ObservationIgnored private var deferredReload: Task<Void, Never>?
    /// Od tylu wpisów sortujemy w tle (poniżej — od razu, bez przeskoku między wątkami).
    nonisolated static let asyncSortThreshold = 1000
    /// Najkrótszy odstęp między odświeżeniami wywołanymi przez obserwatora folderu (folder z ciągłym ruchem nie zaleje interfejsu).
    static let minWatcherReloadInterval: TimeInterval = 0.5
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var watcher: DirectoryWatcher?
    @ObservationIgnored private var watchedPath: String?

    private enum HistoryMode { case push, back, forward, none }

    /// Lokalne adresy są normalizowane; zdalne (`ocremote://`) zostają bez zmian.
    static func normalize(_ url: URL) -> URL { url.isFileURL ? url.standardizedFileURL : url }
    /// Klucz tożsamości lokalizacji: ścieżka lokalna albo pełny adres zdalny (ta sama ścieżka na dwóch serwerach to dwie lokalizacje).
    static func key(_ url: URL) -> String { url.isFileURL ? url.path : url.absoluteString }

    public init(side: PanelSide, location: URL, sortKey: SortKey = .name, sortAscending: Bool = true, showHidden: Bool = false) {
        self.side = side
        self.location = Self.normalize(location)
        self.sortKey = sortKey
        self.sortAscending = sortAscending
        self.showHidden = showHidden
    }

    // MARK: - Pochodne

    public var canGoBack: Bool { !back.isEmpty }
    public var canGoForward: Bool { !forward.isEmpty }
    public var isRemote: Bool { location.isRemoteLocation }
    public var canGoUp: Bool {
        if let r = location.remoteLocation { return !r.path.isRoot }
        return location.path != "/"
    }
    /// Filtr działa na całym drzewie pod bieżącym folderem (wyniki mogą leżeć w podfolderach).
    public var isRecursiveSearch: Bool { searchSubfolders && isFiltering && !isRemote }
    public var isFiltering: Bool { !filterText.trimmingCharacters(in: .whitespaces).isEmpty }
    public var selectedEntries: [FileEntry] {
        guard !selection.isEmpty else { return [] }
        return visibleEntries.filter { selection.contains($0.id) }
    }
    /// Suma rozmiarów zaznaczonych plików, których rozmiar jest znany (foldery nie są liczone).
    public var knownSelectedSize: Int64 {
        guard !selection.isEmpty else { return 0 }
        return visibleEntries.reduce(into: Int64(0)) { sum, e in if selection.contains(e.id) { sum += e.size ?? 0 } }
    }
    public var selectedWithUnknownSize: Int {
        guard !selection.isEmpty else { return 0 }
        return visibleEntries.reduce(into: 0) { count, e in if e.size == nil, selection.contains(e.id) { count += 1 } }
    }

    private func recomputeVisible() {
        if isRecursiveSearch, let results = searchResults { visibleEntries = FileFilter.apply(results, text: filterText) }
        else { visibleEntries = FileFilter.apply(entries, text: filterText) }
    }

    // MARK: - Nawigacja

    public func navigate(to url: URL) { load(Self.normalize(url), mode: .push, select: nil) }

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
        let parent = location.remoteLocation.map { $0.parent.url } ?? location.deletingLastPathComponent().standardizedFileURL
        load(parent, mode: .push, select: [Self.key(child)])
    }

    /// Odświeża bieżący folder. `select` — ścieżki do zaznaczenia po załadowaniu.
    public func reload(selecting select: [URL]? = nil) {
        load(location, mode: .none, select: select.map { Set($0.map { Self.key(Self.normalize($0)) }) })
    }

    public func setShowHidden(_ value: Bool) {
        guard value != showHidden else { return }
        showHidden = value
        reload()
    }

    public func setSort(key: SortKey, ascending: Bool) {
        sortKey = key
        sortAscending = ascending
        sortGeneration &+= 1
        let generation = sortGeneration
        sortTask?.cancel()
        if entries.count < Self.asyncSortThreshold && (searchResults?.count ?? 0) < Self.asyncSortThreshold {
            entries = FileSorter.sorted(entries, by: key, ascending: ascending)
            searchResults = searchResults.map { FileSorter.sorted($0, by: key, ascending: ascending) }
            recomputeVisible()
            onStateChange?()
            return
        }
        // Duża lista: sortowanie `localizedStandardCompare` trwa długo, więc nie blokujemy głównego wątku.
        onStateChange?()
        let current = entries, results = searchResults
        sortTask = Task { [weak self] in
            let sortedEntries = await Self.sortedInBackground(current, key: key, ascending: ascending)
            var sortedResults: [FileEntry]?
            if let results { sortedResults = await Self.sortedInBackground(results, key: key, ascending: ascending) }
            guard let self, generation == self.sortGeneration else { return } // w międzyczasie zmieniono kolejność lub załadowano folder
            self.entries = sortedEntries
            self.searchResults = sortedResults
            self.recomputeVisible()
        }
    }

    /// Sortuje poza głównym wątkiem (małe listy — od razu).
    nonisolated static func sortedInBackground(_ entries: [FileEntry], key: SortKey, ascending: Bool) async -> [FileEntry] {
        if entries.count < asyncSortThreshold { return FileSorter.sorted(entries, by: key, ascending: ascending) }
        return await Task.detached(priority: .userInitiated) { FileSorter.sorted(entries, by: key, ascending: ascending) }.value
    }

    /// Czeka na zakończenie bieżącego ładowania i sortowania w tle (testy).
    public func waitUntilIdle() async {
        await loadTask?.value
        await sortTask?.value
    }

    // MARK: - Ładowanie

    private func load(_ target: URL, mode: HistoryMode, select: Set<FileEntry.ID>?) {
        loadTask?.cancel()
        generation &+= 1
        let gen = generation
        isLoading = true
        let hidden = showHidden
        loadTask = Task { [weak self] in
            do {
                let list: [FileEntry]
                if let remote = target.remoteLocation {
                    guard let lister = self?.remoteLister else { throw NetworkError.unsupported("brak obsługi połączeń zdalnych") }
                    list = try await lister(remote).filter { hidden || !$0.isHidden }
                } else {
                    list = try await DirectoryLister.list(target, showHidden: hidden)
                }
                guard let self, gen == self.generation else { return } // nieaktualny wynik
                let key = self.sortKey, ascending = self.sortAscending
                let sorted = await Self.sortedInBackground(list, key: key, ascending: ascending)
                guard gen == self.generation else { return }
                self.commit(target, sorted, sortedBy: (key, ascending), mode, select)
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
        guard !selection.isEmpty else { return }
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
        guard location.isFileURL else { return }
        let wait = Self.minWatcherReloadInterval - Date().timeIntervalSince(lastWatcherReload)
        if wait > 0 {
            // Za wcześnie po poprzednim odświeżeniu: jedno odroczone odświeżenie zbierze wszystkie zdarzenia z tego czasu.
            guard deferredReload == nil else { return }
            deferredReload = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                self.deferredReload = nil
                self.reloadIfIdle()
            }
            return
        }
        guard !isLoading else { return }
        lastWatcherReload = Date()
        reload()
    }

    private func refreshFreeSpace(for url: URL) {
        Task { [weak self] in
            let space = await Task.detached { Locations.freeSpace(at: url) }.value
            guard let self, self.location == url else { return }
            self.freeSpace = space
        }
    }

    private func commit(_ target: URL, _ list: [FileEntry], sortedBy: (SortKey, Bool), _ mode: HistoryMode, _ select: Set<FileEntry.ID>?) {
        let changed = Self.key(target) != Self.key(location)
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
        if target.isFileURL {
            watchIfNeeded(target)
            refreshFreeSpace(for: target)
        } else {
            // Serwer zdalny: bez obserwatora zmian (odświeżanie ręczne/po operacjach) i bez informacji o wolnym miejscu.
            watcher?.stop(); watcher = nil; watchedPath = nil; freeSpace = nil
        }
        if changed { filterText = "" }
        // Kolejność mogła się zmienić w trakcie ładowania — wtedy sortujemy ponownie (rzadko).
        let ordered = sortedBy == (sortKey, sortAscending) ? list : FileSorter.sorted(list, by: sortKey, ascending: sortAscending)
        sortGeneration &+= 1 // odrzuca sortowanie w tle zlecone przed tym załadowaniem
        let listChanged = ordered != entries
        if listChanged { entries = ordered }  // odświeżenie bez zmian nie przerysowuje tabeli
        if listChanged || changed { recomputeVisible() }
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
        // Zapis ustawień i „ostatnie” dotyczą zmiany lokalizacji; samo odświeżenie tej samej listy nie zmienia niczego do zapisania.
        if changed { onStateChange?() }
    }

    /// Wyszukiwanie w podfolderach z krótkim opóźnieniem (pisanie nie uruchamia setek skanów).
    private func scheduleSearch() {
        searchTask?.cancel()
        guard isRecursiveSearch else {
            searchResults = nil; isSearching = false; searchTruncated = false
            recomputeVisible()
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
                let key = self.sortKey, ascending = self.sortAscending
                var sorted = await Self.sortedInBackground(result.entries, key: key, ascending: ascending)
                guard !Task.isCancelled, self.location == root else { return }
                if key != self.sortKey || ascending != self.sortAscending {
                    sorted = FileSorter.sorted(sorted, by: self.sortKey, ascending: self.sortAscending)
                }
                self.searchResults = sorted
                self.searchTruncated = result.truncated
                self.isSearching = false
                self.recomputeVisible()
                self.pruneSelectionToVisible()
            } catch is CancellationError {
                return
            } catch {
                self?.isSearching = false
            }
        }
    }
}
