import Foundation

/// Błędy warstwy sieciowej. Komunikaty są dla użytkownika i **nie mogą zawierać sekretów** —
/// dane z zewnątrz (komunikaty serwera, biblioteki) zawsze przechodzą przez `Redactor`.
public enum NetworkError: Error, Equatable, Sendable, LocalizedError {
    case dnsFailure(host: String)
    case timeout
    case connectionFailed(String)
    case connectionLost
    case authenticationFailed
    case hostKeyUnknown(HostKeyInfo)
    case hostKeyChanged(expected: String, actual: HostKeyInfo)
    case hostKeyRejected
    case tlsCertificateInvalid(String)
    case insecureConnectionRefused(String)
    case permissionDenied(String)
    case noSpace
    case notFound(String)
    case conflict(String)
    case unsupported(String)
    case invalidPath(String)
    case invalidProfile(String)
    case invalidResponse(String)
    case cancelled
    case other(String)

    public var errorDescription: String? {
        switch self {
        case .dnsFailure(let h): return "Nie udało się znaleźć serwera „\(h)” (błąd DNS)."
        case .timeout: return "Przekroczono czas oczekiwania na serwer."
        case .connectionFailed(let r): return "Nie udało się połączyć z serwerem: \(r)"
        case .connectionLost: return "Połączenie z serwerem zostało przerwane."
        case .authenticationFailed: return "Uwierzytelnianie nie powiodło się (nieprawidłowy użytkownik, hasło lub klucz)."
        case .hostKeyUnknown(let i): return "Nieznany klucz serwera \(i.host):\(i.port) (\(i.keyType), \(i.fingerprint)). Wymagana jest decyzja użytkownika."
        case .hostKeyChanged(let expected, let actual):
            return "UWAGA: klucz serwera \(actual.host):\(actual.port) zmienił się! Zaufany odcisk: \(expected), obecny: \(actual.fingerprint). Połączenie zablokowane — może to być atak typu man-in-the-middle."
        case .hostKeyRejected: return "Klucz serwera nie został zaakceptowany — połączenie przerwane."
        case .tlsCertificateInvalid(let r): return "Certyfikat serwera jest nieprawidłowy lub niezaufany: \(r)"
        case .insecureConnectionRefused(let r): return "Odmowa nieszyfrowanego połączenia: \(r)"
        case .permissionDenied(let p): return "Brak uprawnień do „\(p)” na serwerze."
        case .noSpace: return "Brak miejsca na dysku (lokalnym lub na serwerze)."
        case .notFound(let p): return "„\(p)” nie istnieje na serwerze."
        case .conflict(let p): return "Konflikt: „\(p)” już istnieje lub operacja koliduje z istniejącym zasobem."
        case .unsupported(let op): return "Serwer nie obsługuje operacji: \(op)."
        case .invalidPath(let p): return "Niedozwolona nazwa lub ścieżka: „\(p)”."
        case .invalidProfile(let r): return "Nieprawidłowy profil połączenia: \(r)"
        case .invalidResponse(let r): return "Nieoczekiwana odpowiedź serwera: \(r)"
        case .cancelled: return "Operacja została anulowana."
        case .other(let r): return r
        }
    }

    /// Błąd, po którym nie wiadomo, czy operacja zdalna została wykonana — nie wolno jej ponawiać automatycznie.
    public var leavesOutcomeUnknown: Bool {
        switch self {
        case .timeout, .connectionLost: return true
        default: return false
        }
    }
}

/// Informacje o kluczu hosta SSH pokazywane użytkownikowi przy pierwszym połączeniu.
public struct HostKeyInfo: Equatable, Sendable, Codable {
    public let host: String
    public let port: Int
    public let keyType: String
    /// Odcisk SHA-256 w formacie OpenSSH: „SHA256:…” (base64 bez dopełnienia).
    public let fingerprint: String
    public init(host: String, port: Int, keyType: String, fingerprint: String) {
        self.host = host; self.port = port; self.keyType = keyType; self.fingerprint = fingerprint
    }
}

/// Usuwa sekrety z tekstów, które mogłyby trafić do komunikatów, logów lub UI.
public enum Redactor {
    public static let mask = "•••"

    /// - Parameter secrets: znane wartości sekretów (hasło, passphrase) do zamaskowania w dowolnym miejscu tekstu.
    public static func redact(_ text: String, secrets: [String] = []) -> String {
        var out = text
        for s in secrets where s.count >= 3 { out = out.replacingOccurrences(of: s, with: mask) }
        // user:haslo@host w adresach URL
        out = out.replacingOccurrences(of: #"(?i)([a-z][a-z0-9+.\-]*://[^/\s:@]+):[^/\s@]+@"#, with: "$1:\(mask)@", options: .regularExpression)
        // nagłówki Authorization / Proxy-Authorization / Cookie / tokeny
        out = out.replacingOccurrences(of: #"(?i)((?:proxy-)?authorization|cookie|set-cookie|x-auth-token)\s*[:=]\s*[^\r\n]*"#, with: "$1: \(mask)", options: .regularExpression)
        // PEM / OpenSSH — zawartość klucza prywatnego
        out = out.replacingOccurrences(of: #"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?(-----END [A-Z0-9 ]*PRIVATE KEY-----|$)"#, with: "[klucz prywatny usunięty]", options: .regularExpression)
        // password=…, passwd=…, token=…
        out = out.replacingOccurrences(of: #"(?i)\b(pass(?:word|wd|phrase)?|token|secret)=[^\s&]+"#, with: "$1=\(mask)", options: .regularExpression)
        return out
    }
}
