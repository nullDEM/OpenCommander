import SwiftUI
import OpenCommanderCore

/// Panel informacji o zaznaczeniu aktywnego panelu. Rozmiary folderów liczone są wyłącznie na żądanie.
struct InfoPanel: View {
    let state: AppState

    @State private var measured: FolderSize?
    @State private var measuring = false
    @State private var measureTask: Task<Void, Never>?

    private var panel: PanelState { state.activePanel }
    private var selected: [FileEntry] { panel.selectedEntries }
    /// Zmienia się razem z zaznaczeniem — wynik pomiaru dotyczy tylko bieżącego zaznaczenia.
    private var signature: String { panel.location.path + "|" + selected.map(\.id).sorted().joined(separator: "\n") }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if selected.isEmpty { folderInfo }
                else if selected.count == 1 { singleInfo(selected[0]) }
                else { multiInfo }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.background)
        .onChange(of: signature) { _, _ in resetMeasurement() }
        .accessibilityLabel("Panel informacji")
    }

    // MARK: Widoki

    private var folderInfo: some View {
        VStack(alignment: .leading, spacing: 10) {
            header(icon: NSWorkspace.shared.icon(for: .folder), title: folderTitle, subtitle: "Bieżący folder")
            row("Elementy", Polish.items(panel.entries.count))
            if panel.isFiltering { row("Po filtrze", "\(panel.visibleEntries.count)") }
            if let free = panel.freeSpace { row("Wolne miejsce", ProgressFormat.bytes(free)) }
            pathRow(panel.location.remoteLocation?.path.string ?? panel.location.path)
            Text("Zaznacz element, aby zobaczyć szczegóły.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var folderTitle: String {
        if let r = panel.location.remoteLocation {
            let server = state.serverName(of: panel.location) ?? "Serwer"
            return r.path.lastComponent ?? server
        }
        return panel.location.lastPathComponent.isEmpty ? "/" : panel.location.lastPathComponent
    }

    private func singleInfo(_ e: FileEntry) -> some View {
        // Wpis zdalny ma adres `ocremote://…`, ale jego `.path` wygląda jak ścieżka lokalna — nie wolno pytać o nią lokalnego dysku.
        let remote = e.url.isRemoteLocation
        let attrs = remote ? [:] : ((try? FileManager.default.attributesOfItem(atPath: e.url.path)) ?? [:])
        return VStack(alignment: .leading, spacing: 10) {
            header(icon: e.isPackage ? NSWorkspace.shared.icon(forFile: e.url.path) : IconCache.typeIcon(for: e),
                   title: e.name, subtitle: e.kind)
            if e.isSymbolicLink {
                row("Dowiązanie do", remote ? "—" : ((try? FileManager.default.destinationOfSymbolicLink(atPath: e.url.path)) ?? "nieczytelne"))
            }
            if let size = e.size {
                row("Rozmiar", "\(ProgressFormat.bytes(size)) (\(size.formatted()) B)")
            } else if e.isDirectory && !e.isSymbolicLink && !remote {
                sizeSection
            } else {
                row("Rozmiar", "—")
            }
            if let c = attrs[.creationDate] as? Date { row("Utworzono", c.formatted(date: .abbreviated, time: .shortened)) }
            if let m = e.modificationDate { row("Zmodyfikowano", m.formatted(date: .abbreviated, time: .shortened)) }
            if let perm = attrs[.posixPermissions] as? NSNumber { row("Uprawnienia", String(perm.intValue, radix: 8)) }
            if e.isHidden { row("Ukryty", "tak") }
            pathRow(e.url.remoteLocation?.path.string ?? e.url.path)
            if !remote {
                Button("Pokaż w Finderze") { NSWorkspace.shared.activateFileViewerSelecting([e.url]) }.buttonStyle(.link)
            }
        }
    }

    private var multiInfo: some View {
        let folders = selected.filter { $0.isDirectory && !$0.isSymbolicLink }
        return VStack(alignment: .leading, spacing: 10) {
            header(icon: NSWorkspace.shared.icon(for: .data), title: "Zaznaczono \(Polish.items(selected.count))", subtitle: nil)
            row("Suma rozmiarów plików", ProgressFormat.bytes(panel.knownSelectedSize))
            if !folders.isEmpty {
                row("Foldery", "\(folders.count) — rozmiar nieobliczony")
                if !panel.isRemote { sizeSection }
            }
        }
    }

    /// Przycisk „Oblicz rozmiar” + wynik; nic nie liczy się samo.
    private var sizeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let m = measured {
                row("Rozmiar", ProgressFormat.bytes(m.bytes))
                row("Zawartość", "\(m.files) plików, \(m.folders) folderów")
                if m.unreadable > 0 {
                    Label("Wynik niepełny: \(m.unreadable) elementów nieczytelnych (brak uprawnień).", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            } else if measuring {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Liczenie…").foregroundStyle(.secondary)
                    Button("Anuluj") { measureTask?.cancel() }.buttonStyle(.link)
                }
            } else {
                HStack { Text("Rozmiar").foregroundStyle(.secondary); Spacer()
                    Button("Oblicz rozmiar") { measureSelection() } }
            }
        }
    }

    // MARK: Elementy pomocnicze

    private func header(icon: NSImage, title: String, subtitle: String?) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: icon).resizable().frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).textSelection(.enabled).lineLimit(3)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).textSelection(.enabled).multilineTextAlignment(.trailing)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }

    private func pathRow(_ path: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Ścieżka").font(.callout).foregroundStyle(.secondary)
            Text(path).font(.caption.monospaced()).textSelection(.enabled)
        }
    }

    // MARK: Pomiar

    private func resetMeasurement() {
        measureTask?.cancel()
        measureTask = nil
        measured = nil
        measuring = false
    }

    private func measureSelection() {
        let urls = selected.filter { $0.isDirectory && !$0.isSymbolicLink }.map(\.url)
        guard !urls.isEmpty else { return }
        measuring = true
        measureTask = Task {
            var total = FolderSize()
            do {
                for url in urls {
                    let r = try await FolderSizer.measure(url)
                    total.bytes += r.bytes; total.files += r.files; total.folders += r.folders; total.unreadable += r.unreadable
                }
                measured = total
            } catch { /* anulowano albo zmieniło się zaznaczenie */ }
            measuring = false
        }
    }
}
