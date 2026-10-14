import SwiftUI
import OpenCommanderCore

/// Pasek kart jednego panelu (widoczny, gdy kart jest więcej niż jedna).
struct TabBar: View {
    let tabs: PanelTabs
    let state: AppState

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Array(tabs.tabs.enumerated()), id: \.element.id) { index, tab in
                    TabItem(title: state.tabTitle(tab), path: tab.location.path,
                            isSelected: index == tabs.activeIndex,
                            select: { state.selectTab(tabs.side, index) },
                            close: { state.closeTab(tabs.side, index) })
                        .contextMenu {
                            Button("Zamknij kartę") { state.closeTab(tabs.side, index) }
                            Button("Zamknij pozostałe karty") { state.closeOtherTabs(tabs.side, keeping: index) }
                                .disabled(tabs.tabs.count < 2)
                        }
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
        }
        .frame(height: 30)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Karty panelu")
    }
}

private struct TabItem: View {
    let title: String
    let path: String
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Button(action: select) {
                Text(title.isEmpty ? "/" : title).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 140, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Karta \(title)")
            .accessibilityValue(isSelected ? "aktywna" : "")
            Button(action: close) { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                .buttonStyle(.borderless)
                .opacity(hovering || isSelected ? 1 : 0)
                .help("Zamknij kartę (⌘W)").accessibilityLabel("Zamknij kartę \(title)")
        }
        .font(.callout.weight(isSelected ? .semibold : .regular))
        .foregroundStyle(isSelected ? .primary : .secondary)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6).fill(isSelected ? Color.primary.opacity(0.14) : (hovering ? Color.primary.opacity(0.07) : .clear)))
        .onHover { hovering = $0 }
        .help(path)
    }
}
