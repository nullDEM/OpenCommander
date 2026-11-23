import SwiftUI
import AppKit
import OpenCommanderCore

/// Ikony: pliki i foldery — według typu (jedna ikona na typ, tanio); pakiety `.app` — według ścieżki,
/// bo każdy program ma własną ikonę, a wszystkie mają ten sam typ.
enum IconCache {
    @MainActor private static var typeCache: [String: NSImage] = [:]
    private static let packageCache = NSCache<NSString, NSImage>()

    @MainActor
    static func typeIcon(for entry: FileEntry) -> NSImage {
        let key = entry.isNavigable ? "folder" : (entry.contentType?.identifier ?? "public.data")
        if let hit = typeCache[key] { return hit }
        let image = entry.isNavigable
            ? NSWorkspace.shared.icon(for: .folder)
            : NSWorkspace.shared.icon(for: entry.contentType ?? .data)
        typeCache[key] = image
        return image
    }

    /// Ładuje ikonę poza głównym wątkiem; wynik jest buforowany po ścieżce.
    static func packageIcon(at url: URL) async -> NSImage {
        let key = url.path as NSString
        if let hit = packageCache.object(forKey: key) { return hit }
        let image = await Task.detached(priority: .utility) { NSWorkspace.shared.icon(forFile: url.path) }.value
        packageCache.setObject(image, forKey: key)
        return image
    }
}
