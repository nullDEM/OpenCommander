import Foundation

/// Katalog tymczasowy dla testów w Swift Testing: tworzony w `init`, sprzątany w `deinit` (po zakończeniu testu).
/// Odpowiednik `TempDirTestCase` z testów XCTest — ta sama zasada: testy działają wyłącznie na katalogach tymczasowych.
final class TemporaryDirectory {
    let root: URL

    init() throws {
        // Fizyczna ścieżka (bez symlinku /var → /private/var), by porównania ścieżek były stabilne.
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
        root = base.appendingPathComponent("OpenCommanderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func makeFile(_ relativePath: String, _ content: String = "x") throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
        return url
    }

    @discardableResult
    func makeDirectory(_ relativePath: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
