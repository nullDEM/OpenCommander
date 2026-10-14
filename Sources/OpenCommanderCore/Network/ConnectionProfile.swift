import Foundation

public enum ConnectionProtocol: String, Codable, CaseIterable, Sendable, Identifiable {
    case sftp, ftp, ftps, webdav
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .sftp: return "SFTP (SSH)"
        case .ftp: return "FTP (bez szyfrowania)"
        case .ftps: return "FTPS (FTP przez TLS)"
        case .webdav: return "WebDAV"
        }
    }
}

public enum FTPSMode: String, Codable, CaseIterable, Sendable {
    /// Połączenie zaczyna się jawnie (port 21) i przechodzi na TLS poleceniem AUTH TLS.
    case explicit
    /// TLS od pierwszego bajtu (zwykle port 990).
    case implicit
}

public enum AuthMode: String, Codable, CaseIterable, Sendable {
    case password
    case privateKey
    case anonymous

    public var title: String {
        switch self {
        case .password: return "Hasło"
        case .privateKey: return "Klucz prywatny"
        case .anonymous: return "Anonimowo"
        }
    }
}

/// Odwołanie do sekretu w Keychain. Sam sekret nigdy nie jest częścią profilu.
public struct SecretRef: Hashable, Codable, Sendable {
    public let id: UUID
    public init(id: UUID = UUID()) { self.id = id }
}

/// Konfiguracja połączenia — **bez sekretów** (hasło i passphrase są w Keychain, pod `passwordRef` / `passphraseRef`).
public struct ConnectionProfile: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var proto: ConnectionProtocol
    public var host: String
    public var port: Int
    public var username: String
    /// Katalog początkowy (SFTP/FTP/FTPS). Dla WebDAV ścieżka wynika z `baseURL`.
    public var initialPath: String
    /// Bazowy adres WebDAV (https://host[:port]/prefiks/). Nie może zawierać danych logowania.
    public var baseURL: String?
    public var auth: AuthMode
    /// Ścieżka pliku klucza prywatnego (tylko ścieżka — zawartość klucza nie jest zapisywana).
    public var keyFilePath: String?
    public var passwordRef: SecretRef?
    public var passphraseRef: SecretRef?
    public var ftpsMode: FTPSMode
    /// Jawna zgoda na połączenie bez szyfrowania (zwykłe FTP, WebDAV przez HTTP).
    public var allowInsecure: Bool
    public var connectTimeoutSeconds: Int

    public init(id: UUID = UUID(), name: String, proto: ConnectionProtocol, host: String = "", port: Int? = nil,
                username: String = "", initialPath: String = "/", baseURL: String? = nil, auth: AuthMode = .password,
                keyFilePath: String? = nil, passwordRef: SecretRef? = nil, passphraseRef: SecretRef? = nil,
                ftpsMode: FTPSMode = .explicit, allowInsecure: Bool = false, connectTimeoutSeconds: Int = 20) {
        self.id = id; self.name = name; self.proto = proto; self.host = host
        self.port = port ?? Self.defaultPort(proto, ftpsMode: ftpsMode, baseURL: baseURL)
        self.username = username; self.initialPath = initialPath; self.baseURL = baseURL; self.auth = auth
        self.keyFilePath = keyFilePath; self.passwordRef = passwordRef; self.passphraseRef = passphraseRef
        self.ftpsMode = ftpsMode; self.allowInsecure = allowInsecure; self.connectTimeoutSeconds = connectTimeoutSeconds
    }

    public static func defaultPort(_ proto: ConnectionProtocol, ftpsMode: FTPSMode = .explicit, baseURL: String? = nil) -> Int {
        switch proto {
        case .sftp: return 22
        case .ftp: return 21
        case .ftps: return ftpsMode == .implicit ? 990 : 21
        case .webdav:
            if let u = baseURL.flatMap(URL.init(string:)), u.scheme?.lowercased() == "http" { return 80 }
            return 443
        }
    }

    /// Adres WebDAV po walidacji (https albo http z jawną zgodą).
    public var webDAVURL: URL? { baseURL.flatMap(URL.init(string:)) }

    /// Zwraca pierwszy znaleziony problem albo `nil`, gdy profil jest poprawny.
    public func validationError() -> String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "nazwa nie może być pusta." }
        if !(1...600).contains(connectTimeoutSeconds) { return "limit czasu musi mieścić się w zakresie 1–600 s." }

        switch proto {
        case .webdav:
            guard let s = baseURL?.trimmingCharacters(in: .whitespaces), !s.isEmpty,
                  let u = URL(string: s), let scheme = u.scheme?.lowercased(), let h = u.host, !h.isEmpty else {
                return "podaj pełny adres WebDAV (https://serwer/ścieżka)."
            }
            if u.user != nil || u.password != nil { return "adres nie może zawierać nazwy użytkownika ani hasła — wpisz je w osobnych polach." }
            if scheme == "http" {
                if !allowInsecure { return "WebDAV przez HTTP jest nieszyfrowany — wymaga jawnej zgody (pole „Zezwalam na połączenie bez szyfrowania”)." }
            } else if scheme != "https" {
                return "obsługiwane adresy WebDAV: https:// (oraz http:// z jawną zgodą)."
            }
            if let p = u.port, !(1...65535).contains(p) { return "port w adresie jest nieprawidłowy." }
        case .sftp, .ftp, .ftps:
            let h = host.trimmingCharacters(in: .whitespaces)
            if h.isEmpty { return "podaj adres serwera." }
            if h.contains(where: { $0.isWhitespace || "/@\\?#".contains($0) }) { return "adres serwera zawiera niedozwolone znaki." }
            if !(1...65535).contains(port) { return "port musi mieścić się w zakresie 1–65535." }
            if proto == .ftp && !allowInsecure { return "FTP przesyła dane i hasło bez szyfrowania — wymaga jawnej zgody. Jeśli serwer wspiera szyfrowanie, wybierz FTPS lub SFTP." }
            if proto == .sftp && auth == .anonymous { return "SFTP nie obsługuje logowania anonimowego." }
            if proto != .sftp && auth == .privateKey { return "logowanie kluczem jest dostępne tylko w SFTP." }
        }
        if proto != .webdav || auth != .anonymous {
            if auth != .anonymous && username.trimmingCharacters(in: .whitespaces).isEmpty && proto != .webdav {
                return "podaj nazwę użytkownika."
            }
        }
        if auth == .privateKey && (keyFilePath ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            return "wybierz plik klucza prywatnego."
        }
        return nil
    }

    /// Czy połączenie jest szyfrowane (do ostrzeżeń w interfejsie).
    public var isEncrypted: Bool {
        switch proto {
        case .sftp, .ftps: return true
        case .ftp: return false
        case .webdav: return webDAVURL?.scheme?.lowercased() == "https"
        }
    }

    public var displayAddress: String {
        switch proto {
        case .webdav: return baseURL ?? ""
        default: return "\(host):\(port)"
        }
    }

    public var secretRefs: [SecretRef] { [passwordRef, passphraseRef].compactMap { $0 } }
}
