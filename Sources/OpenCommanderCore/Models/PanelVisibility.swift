import Foundation

/// Który panel jest ukryty. Ukryć można najwyżej jeden — drugi zawsze zostaje widoczny, więc w oknie
/// jest zawsze przynajmniej jeden panel (i jest dokąd przenieść fokus).
public struct PanelVisibility: Equatable, Sendable {
    public private(set) var hidden: PanelSide?

    public init(hidden: PanelSide? = nil) { self.hidden = hidden }

    public func isVisible(_ side: PanelSide) -> Bool { hidden != side }

    /// Widoczny jest tylko jeden panel (drugi ukryty).
    public var isSinglePanel: Bool { hidden != nil }

    /// Czy przełączenie widoczności tego panelu jest dozwolone: nie da się ukryć drugiego panelu, gdy jeden jest już ukryty.
    public func canToggle(_ side: PanelSide) -> Bool { !isVisible(side) || hidden == nil }

    /// Ustawia widoczność panelu. Zwraca `false`, gdy zmiana byłaby niedozwolona (ukrycie obu paneli) — stan wtedy się nie zmienia.
    @discardableResult
    public mutating func setVisible(_ visible: Bool, side: PanelSide) -> Bool {
        if visible {
            if hidden == side { hidden = nil }
            return true
        }
        switch hidden {
        case nil: hidden = side; return true
        case side?: return true
        default: return false
        }
    }

    /// Aktywny panel po zmianie widoczności: ukryty panel nie może być aktywny, więc aktywny staje się widoczny.
    public func resolvedActive(_ active: PanelSide) -> PanelSide {
        isVisible(active) ? active : active.other
    }

    /// Panel, w którym otwieramy elementy „z zewnątrz” (np. wolumin z paska bocznego): preferowany, o ile jest widoczny.
    public func visibleSide(preferring preferred: PanelSide) -> PanelSide {
        isVisible(preferred) ? preferred : preferred.other
    }
}
