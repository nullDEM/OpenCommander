import Foundation

/// Błędy operacji na plikach. Komunikaty są przeznaczone dla użytkownika.
public enum OperationError: Error, Equatable, Sendable, LocalizedError {
    case sourceMissing(String)
    case destinationUnavailable(String)
    case permissionDenied(String)
    case noSpace(String)
    case readOnlyVolume(String)
    case copyIntoItself(String)
    case replaceWouldDestroySource(String)
    case invalidName(String)
    case nameExists(String)
    case sourceNotRemoved(name: String, reason: String)
    case trashFailed(name: String, reason: String)
    case ejectFailed(name: String, reason: String)
    case other(name: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .sourceMissing(let n): return "„\(n)” już nie istnieje (usunięty lub odłączony wolumin)."
        case .destinationUnavailable(let n): return "Folder docelowy „\(n)” jest niedostępny."
        case .permissionDenied(let n): return "Brak uprawnień do „\(n)”."
        case .noSpace(let n): return "Brak miejsca na dysku podczas zapisu „\(n)”."
        case .readOnlyVolume(let n): return "Wolumin jest tylko do odczytu („\(n)”)."
        case .copyIntoItself(let n): return "Nie można skopiować ani przenieść folderu „\(n)” do niego samego lub jego podfolderu."
        case .replaceWouldDestroySource(let n): return "Zastąpienie zniszczyłoby element źródłowy „\(n)”."
        case .invalidName(let r): return "Nieprawidłowa nazwa: \(r)"
        case .nameExists(let n): return "Element o nazwie „\(n)” już istnieje."
        case .sourceNotRemoved(let n, let r):
            return "Skopiowano „\(n)”, ale nie udało się usunąć oryginału: \(r). Obie wersje pozostały."
        case .trashFailed(let n, let r): return "Nie udało się przenieść „\(n)” do Kosza: \(r)"
        case .ejectFailed(let n, let r):
            return "Nie udało się wysunąć „\(n)”: \(r)\nZamknij pliki otwarte z tego woluminu (także w innych aplikacjach) i spróbuj ponownie."
        case .other(let n, let r): return "„\(n)”: \(r)"
        }
    }

    /// Mapuje błąd systemowy na błąd domenowy.
    public static func map(_ error: Error, item: String) -> OperationError {
        if let known = error as? OperationError { return known }
        let ns = error as NSError
        var codes: [(String, Int)] = [(ns.domain, ns.code)]
        if let under = ns.userInfo[NSUnderlyingErrorKey] as? NSError { codes.append((under.domain, under.code)) }
        for (domain, code) in codes {
            if domain == NSCocoaErrorDomain {
                switch code {
                case NSFileNoSuchFileError, NSFileReadNoSuchFileError: return .sourceMissing(item)
                case NSFileReadNoPermissionError, NSFileWriteNoPermissionError: return .permissionDenied(item)
                case NSFileWriteOutOfSpaceError: return .noSpace(item)
                case NSFileWriteVolumeReadOnlyError: return .readOnlyVolume(item)
                case NSFileWriteFileExistsError: return .nameExists(item)
                default: break
                }
            } else if domain == NSPOSIXErrorDomain {
                switch Int32(code) {
                case ENOENT: return .sourceMissing(item)
                case EACCES, EPERM: return .permissionDenied(item)
                case ENOSPC: return .noSpace(item)
                case EROFS: return .readOnlyVolume(item)
                case EEXIST: return .nameExists(item)
                default: break
                }
            }
        }
        return .other(name: item, reason: ns.localizedDescription)
    }
}
