import SwiftUI
import OpenCommanderCore

/// Jeden panel: karty, nagłówek z okruszkami, filtr, lista plików i pasek stanu.
/// Poszczególne części to osobne widoki — każdy czyta tylko te dane panelu, których potrzebuje.
struct PanelView: View {
    @Bindable var panel: PanelState
    let tabs: PanelTabs
    let state: AppState
    var focus: FocusState<PanelSide?>.Binding

    @State private var showFilter = false
    @FocusState private var filterFocused: Bool

    private var isActive: Bool { state.active == panel.side }

    var body: some View {
        VStack(spacing: 0) {
            if tabs.tabs.count > 1 { TabBar(tabs: tabs, state: state); Divider() }
            // Animacja tylko tam, gdzie zmienia się wygląd aktywności — nie obejmuje tabeli z listą plików.
            PanelHeader(panel: panel, state: state, isActive: isActive)
                .animation(.easeInOut(duration: 0.12), value: isActive)
            Divider()
            if showFilter || panel.isFiltering {
                PanelFilterBar(panel: panel, showFilter: $showFilter, isFieldFocused: $filterFocused, panelFocus: focus)
            }
            if let error = panel.loadError { PanelErrorBanner(error: error) { panel.reload() } }
            PanelTable(panel: panel, state: state, focus: focus)
            PanelStatusBar(panel: panel)
        }
        .background(.background)
        // Wyraźny wskaźnik aktywnego panelu: pas w kolorze akcentu nad nagłówkiem.
        .overlay(alignment: .top) {
            Rectangle().fill(isActive ? Color.accentColor : Color.clear).frame(height: 3)
                .animation(.easeInOut(duration: 0.12), value: isActive)
        }
        .simultaneousGesture(TapGesture().onEnded { state.active = panel.side })
        .accessibilityElement(children: .contain)
        .accessibilityLabel(panel.side == .left ? "Panel lewy" : "Panel prawy")
        .accessibilityValue(isActive ? "aktywny" : "")
        .onChange(of: state.filterFocusToken) { _, _ in
            guard isActive else { return }
            showFilter = true
            filterFocused = true
        }
    }
}
