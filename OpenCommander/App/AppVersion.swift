import Foundation

/// Wersja uruchomionej aplikacji: numer z Info.plist oraz commit git wpisany przy budowaniu (skrypt w `project.yml`),
/// dzięki czemu z menu Pomoc widać, z którego commita pochodzi działająca kopia.
enum AppVersion {
    static var menuTitle: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let commit = info["OCGitCommit"] as? String ?? "nieznany"
        let count = info["OCGitCount"] as? String
        let number = count.map { " · #\($0)" } ?? ""
        return "Wersja \(version) · commit \(commit)\(number)"
    }
}
