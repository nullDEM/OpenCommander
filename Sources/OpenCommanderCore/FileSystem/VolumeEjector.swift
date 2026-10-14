import AppKit
import Foundation

/// Wysuwanie woluminów. Nie robi nic poza tym, o co poprosił użytkownik: odmontowuje i wysuwa jeden wolumin.
public enum VolumeEjector {
    /// Czy ścieżka leży na woluminie o danym punkcie montowania (lub nim jest).
    public static func isInside(_ path: String, volume volumePath: String) -> Bool {
        path == volumePath || path.hasPrefix(volumePath == "/" ? "/" : volumePath + "/")
    }

    /// Najgłębszy wolumin zawierający `url` (np. do wysunięcia dysku aktywnego panelu).
    public static func volume(containing url: URL, in volumes: [VolumeInfo]) -> VolumeInfo? {
        volumes.filter { isInside(url.path, volume: $0.url.path) }.max { $0.url.path.count < $1.url.path.count }
    }

    /// Wysuwa wolumin poza głównym wątkiem. Rzuca `OperationError`, gdy system odmówi (np. wolumin zajęty).
    public static func eject(_ volume: VolumeInfo) async throws {
        guard volume.canEject else {
            throw OperationError.ejectFailed(name: volume.name, reason: "ten wolumin nie może zostać wysunięty z aplikacji.")
        }
        let url = volume.url
        let task = Task.detached { try NSWorkspace.shared.unmountAndEjectDevice(at: url) }
        do {
            try await task.value
        } catch {
            throw OperationError.ejectFailed(name: volume.name, reason: (error as NSError).localizedDescription)
        }
    }
}
