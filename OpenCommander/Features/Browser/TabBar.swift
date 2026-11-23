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
