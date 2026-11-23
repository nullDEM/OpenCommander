import SwiftUI
import OpenCommanderCore

/// Klikalne okruszki ścieżki (dla woluminów zewnętrznych korzeniem jest sam wolumin).
struct BreadcrumbBar: View, Equatable {
    let url: URL
    var serverName: String?
    let onSelect: (URL) -> Void

    /// Porównujemy tylko dane widoku; domknięcie `onSelect` zawsze robi to samo (nawigacja panelu).
    static func == (a: BreadcrumbBar, b: BreadcrumbBar) -> Bool { a.url == b.url && a.serverName == b.serverName }

    private var items: [Breadcrumb] {
        guard let r = url.remoteLocation else { return Breadcrumbs.items(for: url) }
        // Serwer zdalny: korzeń to nazwa połączenia, dalej składowe ścieżki zdalnej.
        var out = [Breadcrumb(title: serverName ?? "Serwer", url: RemoteLocation(connectionID: r.connectionID, path: .root).url)]
        var path = RemotePath.root
        for c in r.path.components {
            path = (try? path.appending(c)) ?? path
            out.append(Breadcrumb(title: c, url: RemoteLocation(connectionID: r.connectionID, path: path).url))
        }
        return out
    }

    var body: some View {
        let items = self.items
        // Przewijany widok bez żadnego sprzężenia rozmiaru z kontenerem (GeometryReader + minWidth powodował
        // lawinę przeliczeń układu w podzielonym widoku). Krótka ścieżka stoi od lewej; długa jest przewijana
        // do końca jawnie — przy pojawieniu się, zmianie folderu i zmianie szerokości (pomiar tylko w tle).
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) { row(items) }
                .onAppear { scrollToEnd(proxy, items) }
                .onChange(of: url) { _, _ in scrollToEnd(proxy, items) }
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onChange(of: geo.size.width) { _, _ in scrollToEnd(proxy, items) }
                    }
                )
        }
        .frame(height: 18)
        .accessibilityLabel("Ścieżka: \(url.remoteLocation?.path.string ?? url.path)")
    }

    private static let endMarker = "breadcrumb-end"

    private func scrollToEnd(_ proxy: ScrollViewProxy, _ items: [Breadcrumb]) {
        guard !items.isEmpty else { return }
        // Pierwsze przewinięcie po bieżącym układzie, drugie — gdy szerokości segmentów są już ustalone.
        Task { @MainActor in
            proxy.scrollTo(Self.endMarker, anchor: .trailing)
            try? await Task.sleep(for: .milliseconds(120))
            proxy.scrollTo(Self.endMarker, anchor: .trailing)
        }
    }

    private func row(_ items: [Breadcrumb]) -> some View {
        HStack(spacing: 3) {
            ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                if idx > 0 { Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary) }
                Button { onSelect(item.url) } label: {
                    Text(item.title)
                        .fontWeight(idx == items.count - 1 ? .semibold : .regular)
                        .foregroundStyle(idx == items.count - 1 ? .primary : .secondary)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .help(item.url.remoteLocation?.path.string ?? item.url.path)
            }
            // Niewidoczny znacznik końca — cel przewijania (osobny identyfikator, bez kolizji z ForEach).
            Color.clear.frame(width: 1, height: 1).id(Self.endMarker)
        }
        .fixedSize()
    }
}
