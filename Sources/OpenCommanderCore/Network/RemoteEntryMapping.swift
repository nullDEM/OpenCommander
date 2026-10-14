import Foundation
import UniformTypeIdentifiers

public extension RemoteEntry {
    /// Wpis zdalny jako `FileEntry` panelu: adres = `ocremote://…` (nie `file://`), więc tabela, zaznaczenie i sortowanie
    /// działają bez zmian, a operacje lokalne (Kosz, rename lokalny, Quick Look) nie mogą się do niego odnieść.
    func fileEntry(in directory: RemoteLocation) -> FileEntry? {
        guard let loc = try? directory.appending(name) else { return nil }
        let isLink = kind == .symlink
        // Dowiązanie do folderu pozwala wejść do środka (jedna kontrolowana warstwa); transfery go nie rozwijają.
        let isDir = kind == .directory || (isLink && symlinkTargetIsDirectory == true)
        let ext = (name as NSString).pathExtension
        let type: UTType? = isDir ? .folder : (ext.isEmpty ? nil : UTType(filenameExtension: ext))
        let label: String
        if isLink { label = "Dowiązanie symboliczne" }
        else if isDir { label = "Folder" }
        else { label = type?.localizedDescription ?? (kind == .other ? "Plik specjalny" : "Dokument") }
        return FileEntry(url: loc.url, name: name, isDirectory: isDir, isSymbolicLink: isLink, isPackage: false,
                         isHidden: name.hasPrefix("."), size: (isDir || isLink) ? nil : size,
                         modificationDate: modified, kind: label, contentType: type)
    }
}
