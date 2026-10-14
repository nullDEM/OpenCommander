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

    public func load() -> [ConnectionProfile] {
        guard let data = defaults.data(forKey: key),
              let list = try? JSONDecoder().decode([ConnectionProfile].self, from: data) else { return [] }
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
