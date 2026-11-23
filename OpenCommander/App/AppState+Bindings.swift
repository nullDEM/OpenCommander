import Foundation
import OpenCommanderCore

/// Zapisywalne właściwości pod `$state.…` — widoki wiążą się z nimi bezpośrednio zamiast składać `Binding(get:set:)` w `body`.
extension AppState {
    /// Okno potwierdzenia przeniesienia do Kosza; zamknięcie bez potwierdzenia czyści oczekującą listę.
    var showsTrashDialog: Bool {
        get { !pendingTrash.isEmpty }
        set { if !newValue { pendingTrash = [] } }
    }

    /// Okno potwierdzenia usunięcia na serwerze; zamknięcie bez potwierdzenia porzuca żądanie.
    var showsRemoteDeleteDialog: Bool {
        get { pendingRemoteDelete != nil }
        set { if !newValue { pendingRemoteDelete = nil } }
    }

    /// Alert z komunikatem błędu; zamknięcie czyści komunikat.
    var showsAlert: Bool {
        get { alertMessage != nil }
        set { if !newValue { alertMessage = nil } }
    }

    /// Widoczność paneli (przyciski paska narzędzi): zapis przechodzi przez `setPanelVisible`, który pilnuje, by jeden panel został.
    var showsLeftPanel: Bool {
        get { panelVisibility.isVisible(.left) }
        set { setPanelVisible(.left, newValue) }
    }

    var showsRightPanel: Bool {
        get { panelVisibility.isVisible(.right) }
        set { setPanelVisible(.right, newValue) }
    }

    /// Pliki ukryte: zmiana przechodzi przez `setShowHidden` (odświeża oba panele i zapisuje ustawienie).
    var showHiddenFiles: Bool {
        get { showHidden }
        set { setShowHidden(newValue) }
    }

    /// Okno konfliktu nazw. Zamyka się wyłącznie przez decyzję użytkownika (rozwiązanie konfliktu w `OperationCenter`),
    /// więc zapis wartości jest celowo ignorowany — nie da się go zamknąć zostawiając operację bez odpowiedzi.
    var conflictSheetItem: PendingConflict? {
        get { operations.pendingConflict }
        set {}
    }
}
