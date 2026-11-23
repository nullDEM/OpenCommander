import SwiftUI
import AppKit
import OpenCommanderCore

struct NameCell: View {
    let entry: FileEntry
    /// W wynikach wyszukiwania w podfolderach: folder, względem którego pokazujemy ścieżkę wyniku.
    var base: URL?
    /// Własna ikona pakietu (np. programu); do czasu załadowania widać ikonę typu.
    @State private var packageIcon: NSImage?

    private var relativeFolder: String? {
        guard let base else { return nil }
        let parent = entry.url.deletingLastPathComponent().path
        guard parent != base.path, parent.hasPrefix(base.path + "/") else { return nil }
        return String(parent.dropFirst(base.path.count + 1))
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: packageIcon ?? IconCache.typeIcon(for: entry)).resizable().frame(width: 16, height: 16)
            Text(entry.name).italic(entry.isSymbolicLink).lineLimit(1).truncationMode(.middle)
            if let sub = relativeFolder {
                Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            if entry.isSymbolicLink {
                Image(systemName: "arrow.turn.up.right").font(.caption).foregroundStyle(.secondary)
                    .help("Dowiązanie symboliczne")
            }
        }
        .opacity(entry.isHidden ? 0.6 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(entry.isSymbolicLink ? "\(entry.name), dowiązanie symboliczne" : entry.name)
        .task(id: entry.id) {
            guard entry.isPackage else { packageIcon = nil; return }
            packageIcon = await IconCache.packageIcon(at: entry.url)
        }
    }
}
