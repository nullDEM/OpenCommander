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
    @AppStorage(FileListSetting.key) private var fastFileList = true
    @FocusState private var filterFocused: Bool

    private var isActive: Bool { state.active == panel.side }

    /// Szybka lista (`NSTableView`) na macOS 15+, chyba że wyłączona w menu Widok; inaczej tabela SwiftUI.
    @ViewBuilder private var fileList: some View {
        if #available(macOS 15.0, *), fastFileList {
            FastPanelTable(panel: panel, state: state, focus: focus)
        } else {
            PanelTable(panel: panel, state: state, focus: focus)
        }
    }

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
            fileList
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
