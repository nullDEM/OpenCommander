import Foundation
import Observation

/// Zapisana przestrzeń robocza: karty i lokalizacje obu paneli.
public struct Workspace: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var left: [PanelSettings]
    public var leftActive: Int
    public var right: [PanelSettings]
    public var rightActive: Int
    public var activePanel: PanelSide

    public init(id: UUID = UUID(), name: String, left: [PanelSettings], leftActive: Int,
                right: [PanelSettings], rightActive: Int, activePanel: PanelSide = .left) {
        self.id = id; self.name = name
        self.left = left; self.leftActive = leftActive
        self.right = right; self.rightActive = rightActive
        self.activePanel = activePanel
    }
}

public enum Workspaces {
    /// Zapis pod istniejącą nazwą jest odrzucany — przestrzeń nigdy nie jest po cichu nadpisywana.
    public static func validate(name: String, in list: [Workspace]) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw OperationError.invalidName("nazwa przestrzeni nie może być pusta.") }
        if list.contains(where: { $0.name.compare(trimmed, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) {
            throw OperationError.nameExists(trimmed)
        }
    }
}

/// Karty jednego panelu. Każda karta to osobny `PanelState` (własna lokalizacja, historia, zaznaczenie,
/// sortowanie, filtr, ładowanie i błąd). Zawsze istnieje co najmniej jedna karta.
@MainActor @Observable
public final class PanelTabs {
    public static let maxTabs = 10

    public let side: PanelSide
    public private(set) var tabs: [PanelState]
    public private(set) var activeIndex: Int

    @ObservationIgnored private let factory: (PanelSettings) -> PanelState

    /// `factory` tworzy kartę z ustawień (lokalizacja, sortowanie) — ustala też ukryte pliki i powiadomienia.
    public init(side: PanelSide, settings: [PanelSettings], activeIndex: Int, factory: @escaping (PanelSettings) -> PanelState) {
        self.side = side
        self.factory = factory
        let list = settings.isEmpty ? [PanelSettings(path: Locations.home.path)] : Array(settings.prefix(Self.maxTabs))
        self.tabs = list.map(factory)
        self.activeIndex = min(max(activeIndex, 0), list.count - 1)
        active.reload()
    }

    public var active: PanelState { tabs[activeIndex] }
    public var canAddTab: Bool { tabs.count < Self.maxTabs }
    public var snapshot: [PanelSettings] { tabs.map(Self.settings) }

    static func settings(_ p: PanelState) -> PanelSettings {
        PanelSettings(path: p.location.isFileURL ? p.location.path : NSHomeDirectory(), sortKey: p.sortKey, sortAscending: p.sortAscending)
    }

    /// Nowa karta; domyślnie z lokalizacją i sortowaniem aktywnej.
    @discardableResult
    public func addTab(from settings: PanelSettings? = nil, activate: Bool = true) -> PanelState? {
        guard canAddTab else { return nil }
        let tab = factory(settings ?? Self.settings(active))
        tabs.append(tab)
        if activate { activeIndex = tabs.count - 1 }
        tab.reload()
        return tab
    }

    /// Zamyka kartę; ostatniej karty nie da się zamknąć. Zwraca, czy zamknięto.
    @discardableResult
    public func closeTab(at index: Int) -> Bool {
        guard tabs.count > 1, tabs.indices.contains(index) else { return false }
        tabs.remove(at: index)
        if index < activeIndex { activeIndex -= 1 }
        else if index == activeIndex { activeIndex = min(index, tabs.count - 1); active.reload() }
        return true
    }

    public func select(_ index: Int) {
        guard tabs.indices.contains(index), index != activeIndex else { return }
        activeIndex = index
        active.reload() // karta w tle mogła się zestarzeć
    }

    public func selectNext() { select((activeIndex + 1) % tabs.count) }
    public func selectPrevious() { select((activeIndex - 1 + tabs.count) % tabs.count) }

    /// Zastępuje wszystkie karty (np. przy otwarciu przestrzeni roboczej).
    public func replaceAll(with settings: [PanelSettings], activeIndex: Int) {
        let list = settings.isEmpty ? [Self.settings(active)] : Array(settings.prefix(Self.maxTabs))
        tabs = list.map(factory)
        self.activeIndex = min(max(activeIndex, 0), list.count - 1)
        active.reload()
    }
}
