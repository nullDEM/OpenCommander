import Foundation
import OpenCommanderCore

/// Zdalne usuwanie czeka na potwierdzenie: serwer, ścieżka, liczba elementów.
struct RemoteDeleteRequest: Identifiable {
    let id = UUID()
    let entries: [FileEntry]
    let serverName: String
    let path: String
}
