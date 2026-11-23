import SwiftUI
import OpenCommanderCore

/// Nagłówek panelu: nawigacja (wstecz / dalej / w górę), okruszki ścieżki, wybór folderu i nowa karta.
struct PanelHeader: View {
    let panel: PanelState
    let state: AppState
    let isActive: Bool

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                Button { panel.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!panel.canGoBack).help("Wstecz (⌘[)").accessibilityLabel("Wstecz")
                Button { panel.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!panel.canGoForward).help("Dalej (⌘])").accessibilityLabel("Dalej")
                Button { panel.goUp() } label: { Image(systemName: "arrow.up") }
                    .disabled(!panel.canGoUp).help("Folder nadrzędny (⌘↑)").accessibilityLabel("Folder nadrzędny")
            }
            // `.equatable()`: bez tego domknięcie `onSelect` (nieporównywalne) wymuszałoby przeliczenie okruszków przy każdej zmianie zaznaczenia.
            BreadcrumbBar(url: panel.location, serverName: state.serverName(of: panel.location), onSelect: { panel.navigate(to: $0) })
                .equatable()
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(isActive ? 0.09 : 0.05)))
            if panel.isLoading { ProgressView().controlSize(.small).accessibilityLabel("Ładowanie") }
            Button(action: chooseFolder) { Image(systemName: "folder") }
                .help("Wybierz folder… (⇧⌘O)").accessibilityLabel("Wybierz folder")
            Button(action: newTab) { Image(systemName: "plus.square.on.square") }
                .help("Nowa karta (⌘T)").accessibilityLabel("Nowa karta")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10).padding(.top, 9).padding(.bottom, 6)
        // Sygnał aktywności niezależny od koloru akcentu (bywa grafitowy): nieaktywny nagłówek jest przygaszony.
        .opacity(isActive ? 1 : 0.6)
        .background(isActive ? Color.accentColor.opacity(0.12) : Color.clear)
    }

    private func chooseFolder() {
        state.active = panel.side
        state.chooseFolder()
    }

    private func newTab() {
        state.active = panel.side
        state.newTab()
    }
}
