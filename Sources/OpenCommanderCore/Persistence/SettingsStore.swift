import Foundation

public struct PanelSettings: Codable, Equatable, Sendable {
    public var path: String
    public var sortKey: SortKey
    public var sortAscending: Bool
    public init(path: String, sortKey: SortKey = .name, sortAscending: Bool = true) {
        self.path = path; self.sortKey = sortKey; self.sortAscending = sortAscending
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var left: PanelSettings
    public var right: PanelSettings
    public var showHidden: Bool
    public var activePanel: PanelSide
    public var operationsExpanded: Bool
    public var favorites: [String]
    public var recents: [String]
    public var inspectorVisible: Bool
    /// Wszystkie karty paneli. `left`/`right` pozostają ustawieniami aktywnej karty (zgodność z wersją 0.1).
    public var leftTabs: [PanelSettings]
    public var rightTabs: [PanelSettings]
    public var leftActiveTab: Int
    public var rightActiveTab: Int
    public var workspaces: [Workspace]

    public init(left: PanelSettings, right: PanelSettings, showHidden: Bool = false,
                activePanel: PanelSide = .left, operationsExpanded: Bool = true,
                favorites: [String] = [], recents: [String] = [], inspectorVisible: Bool = false,
                leftTabs: [PanelSettings] = [], rightTabs: [PanelSettings] = [],
                leftActiveTab: Int = 0, rightActiveTab: Int = 0, workspaces: [Workspace] = []) {
        self.leftTabs = leftTabs; self.rightTabs = rightTabs
        self.leftActiveTab = leftActiveTab; self.rightActiveTab = rightActiveTab; self.workspaces = workspaces
        self.left = left; self.right = right; self.showHidden = showHidden
        self.activePanel = activePanel; self.operationsExpanded = operationsExpanded
        self.favorites = favorites; self.recents = recents; self.inspectorVisible = inspectorVisible
    }

    // Nowe pola są opcjonalne w zapisanych danych — ustawienia z wersji 0.1 nadal się wczytują.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        left = try c.decode(PanelSettings.self, forKey: .left)
        right = try c.decode(PanelSettings.self, forKey: .right)
        showHidden = try c.decodeIfPresent(Bool.self, forKey: .showHidden) ?? false
        activePanel = try c.decodeIfPresent(PanelSide.self, forKey: .activePanel) ?? .left
        operationsExpanded = try c.decodeIfPresent(Bool.self, forKey: .operationsExpanded) ?? true
        favorites = try c.decodeIfPresent([String].self, forKey: .favorites) ?? []
        recents = try c.decodeIfPresent([String].self, forKey: .recents) ?? []
        inspectorVisible = try c.decodeIfPresent(Bool.self, forKey: .inspectorVisible) ?? false
        leftTabs = try c.decodeIfPresent([PanelSettings].self, forKey: .leftTabs) ?? []
        rightTabs = try c.decodeIfPresent([PanelSettings].self, forKey: .rightTabs) ?? []
        leftActiveTab = try c.decodeIfPresent(Int.self, forKey: .leftActiveTab) ?? 0
        rightActiveTab = try c.decodeIfPresent(Int.self, forKey: .rightActiveTab) ?? 0
        workspaces = try c.decodeIfPresent([Workspace].self, forKey: .workspaces) ?? []
    }

    public static var defaults: AppSettings {
        let home = Locations.home.path
        return AppSettings(left: PanelSettings(path: home), right: PanelSettings(path: home))
    }
}

public struct SettingsStore {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "OpenCommander.settings.v1") {
        self.defaults = defaults
        self.key = key
    }

    public var backupKey: String { key + ".unreadable-backup" }

    public func load() -> AppSettings {
        guard let data = defaults.data(forKey: key) else { return .defaults }
        guard let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            // Nieczytelne ustawienia (np. po zmianie formatu) zachowujemy, zanim następny zapis je nadpisze.
            if defaults.data(forKey: backupKey) == nil { defaults.set(data, forKey: backupKey) }
            return .defaults
        }
        return settings
    }

    public func save(_ settings: AppSettings) {
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: key) }
    }
}
