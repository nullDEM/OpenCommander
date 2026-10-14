import Foundation

/// Decyzja, co zrobić z elementami upuszczonymi na panel. Silnik i tak chroni przed nadpisaniem
/// i kopiowaniem folderu do siebie; tu odsiewamy tylko operacje bez sensu.
public enum DropPlanner {
    /// Przeniesienie tylko w obrębie jednego woluminu i bez klawisza ⌥; w pozostałych przypadkach kopia.
    public static func kind(sources: [URL], destination: URL, optionHeld: Bool) -> OperationKind {
        if optionHeld { return .copy }
        let destVolume = volume(of: destination)
        let sameVolume = !sources.isEmpty && destVolume != nil && sources.allSatisfy { volume(of: $0) == destVolume }
        return sameVolume ? .move : .copy
    }

    /// Pomija elementy, które już leżą w folderze docelowym (upuszczenie na własny folder) lub nim są.
    public static func effectiveSources(_ sources: [URL], destination: URL) -> [URL] {
        let dest = destination.standardizedFileURL.path
        return sources.filter {
            let u = $0.standardizedFileURL
            return u.deletingLastPathComponent().path != dest && u.path != dest
        }
    }

    private static func volume(of url: URL) -> String? {
        let v = try? url.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        return v.map { String(describing: $0) }
    }
}
