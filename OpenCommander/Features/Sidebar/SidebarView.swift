import SwiftUI
import OpenCommanderCore

struct SidebarView: View {
    let state: AppState

    private var places: [(String, String, URL)] { Locations.standard() }

    /// Kandydaci do podświetlenia w kolejności pierwszeństwa: ulubione, miejsca, woluminy.
    private var candidates: [(id: String, url: URL)] {
        state.favorites.map { ("fav:" + $0.path, $0) }
        + places.map { ("place:" + $0.2.path, $0.2) }
        + state.volumes.map { ("vol:" + $0.url.path, $0.url) }
    }

    /// Pozycja odpowiadająca aktywnemu panelowi: najdłuższy pasujący prefiks; przy remisie wygrywa wcześniejsza sekcja.
    private var currentSelection: String? {
        let path = state.activePanel.location.path
        let matching = candidates.filter { VolumeEjector.isInside(path, volume: $0.url.path) }
        let best = matching.map { $0.url.path.count }.max()
        return matching.first { $0.url.path.count == best }?.id
    }

    var body: some View {
        List(selection: Binding<String?>(
            get: { currentSelection },
            set: { id in
                guard let id else { return }
                if id.hasPrefix("ws:") {
                    if let w = state.workspaces.first(where: { "ws:" + $0.id.uuidString == id }) { state.applyWorkspace(w) }
                    return
                }
                guard let url = candidates.first(where: { $0.id == id })?.url ?? recentURL(id) else { return }
                if id.hasPrefix("vol:") {
                    // Dyski i woluminy zawsze otwierają się w prawym panelu.
                    state.active = .right
                    state.right.navigate(to: url)
                } else {
                    state.activePanel.navigate(to: url)
                }
            }
        )) {
            if !state.favorites.isEmpty {
                Section("Ulubione") {
                    ForEach(state.favorites, id: \.path) { url in
                        let exists = FileManager.default.fileExists(atPath: url.path)
                        Label(url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent, systemImage: "star.fill")
                            .foregroundStyle(exists ? .primary : .secondary)
                            .lineLimit(1).truncationMode(.middle)
                            .tag("fav:" + url.path)
                            .help(exists ? url.path : "\(url.path) — folder niedostępny")
                            .contextMenu { Button("Usuń z ulubionych") { state.removeFavorite(url) } }
                    }
                }
            }
            if !state.workspaces.isEmpty {
                Section("Przestrzenie") {
                    ForEach(state.workspaces) { w in
                        Label(w.name, systemImage: "rectangle.split.2x1")
                            .lineLimit(1).tag("ws:" + w.id.uuidString)
                            .help("Karty i lokalizacje obu paneli: \(w.left.count) + \(w.right.count)")
                            .contextMenu { Button("Usuń przestrzeń", role: .destructive) { state.deleteWorkspace(w) } }
                    }
                }
            }
            Section("Miejsca") {
                ForEach(places, id: \.2) { title, icon, url in
                    Label(title, systemImage: icon).tag("place:" + url.path).help(url.path)
                        .contextMenu { favoriteButton(url) }
                }
            }
            Section("Woluminy") {
                ForEach(state.volumes) { volume in
                    HStack(spacing: 4) {
                        Label(volume.name, systemImage: volume.isInternal ? "internaldrive" : "externaldrive")
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        if state.ejecting.contains(volume.id) {
                            ProgressView().controlSize(.small).accessibilityLabel("Wysuwanie")
                        } else if volume.canEject {
                            Button { state.eject(volume) } label: { Image(systemName: "eject.fill") }
                                .buttonStyle(.borderless)
                                .help("Wysuń „\(volume.name)”")
                                .accessibilityLabel("Wysuń \(volume.name)")
                        }
                    }
                    .tag("vol:" + volume.url.path).help(volume.url.path)
                    .contextMenu {
                        if volume.canEject { Button("Wysuń „\(volume.name)”") { state.eject(volume) } }
                    }
                }
            }
            if !state.recents.isEmpty {
                Section("Ostatnie") {
                    ForEach(state.recents.prefix(8), id: \.path) { url in
                        Label(url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent, systemImage: "clock")
                            .lineLimit(1).truncationMode(.middle)
                            .tag("recent:" + url.path).help(url.path)
                            .contextMenu { favoriteButton(url) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .accessibilityLabel("Pasek boczny: ulubione, miejsca, woluminy i ostatnie lokalizacje")
    }

    private func recentURL(_ id: String) -> URL? {
        id.hasPrefix("recent:") ? URL(fileURLWithPath: String(id.dropFirst("recent:".count))) : nil
    }

    @ViewBuilder
    private func favoriteButton(_ url: URL) -> some View {
        if state.isFavorite(url) {
            Button("Usuń z ulubionych") { state.removeFavorite(url) }
        } else {
            Button("Dodaj do ulubionych") { state.addFavorite(url) }
        }
    }
}
