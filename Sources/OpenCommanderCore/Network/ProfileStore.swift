import Foundation

/// Trwały zapis profili połączeń (JSON w UserDefaults, własny klucz). Zawiera wyłącznie konfigurację —
/// `ConnectionProfile` nie ma pól na hasła ani klucze, więc nie ma jak ich tu zapisać.
public struct ProfileStore {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "OpenCommander.connections.v1") {
        self.defaults = defaults
        self.key = key
    }

    /// Klucz, pod którym zachowywane są dane, których nie dało się odczytać (np. po zmianie formatu) — zanim zostaną nadpisane.
    public var backupKey: String { key + ".unreadable-backup" }

    public func load() -> [ConnectionProfile] {
        guard let data = defaults.data(forKey: key) else { return [] }
        guard let list = try? JSONDecoder().decode([ConnectionProfile].self, from: data) else {
            // Nie kasujemy po cichu zapisanych połączeń: następny zapis nadpisałby nieczytelne dane pustą listą.
            if defaults.data(forKey: backupKey) == nil { defaults.set(data, forKey: backupKey) }
            return []
        }
        return list
    }

    public func save(_ profiles: [ConnectionProfile]) {
        if let data = try? JSONEncoder().encode(profiles) { defaults.set(data, forKey: key) }
    }

    /// Sekrety odwoływane **tylko** przez usuwany profil — bezpieczne do skasowania.
    /// Odwołania współdzielone z innymi profilami zostają.
    public static func exclusiveSecretRefs(of removed: ConnectionProfile, among all: [ConnectionProfile]) -> [SecretRef] {
        let others = Set(all.filter { $0.id != removed.id }.flatMap(\.secretRefs))
        return removed.secretRefs.filter { !others.contains($0) }
    }
}
