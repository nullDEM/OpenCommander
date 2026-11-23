import SwiftUI
import OpenCommanderCore

struct RootView: View {
    @Bindable var state: AppState
    @FocusState private var focus: PanelSide?

    var body: some View {
        NavigationSplitView {
            SidebarView(state: state)
                .navigationSplitViewColumnWidth(min: 150, ideal: 190, max: 260)
        } detail: {
            VStack(spacing: 0) {
                TwoPaneSplit(hidden: state.panelVisibility.hidden) {
                    PanelView(panel: state.left, tabs: state.tabsLeft, state: state, focus: $focus)
                        .id(state.left.id) // nowa karta = świeży stan widoku (filtr, podgląd)
                } right: {
                    PanelView(panel: state.right, tabs: state.tabsRight, state: state, focus: $focus)
                        .id(state.right.id)
                }
                OperationsBar(state: state)
            }
            .inspector(isPresented: $state.showInspector) {
                InfoPanel(state: state)
                    .inspectorColumnWidth(min: 220, ideal: 270, max: 360)
            }
        }
        .toolbar { MainToolbar(state: state) }
        .onChange(of: focus) { _, new in if let new { state.active = new } }
        .onChange(of: state.active) { _, new in focus = new; state.persist() }
        .onAppear { focus = state.active }
        .sheet(item: $state.sheet) { sheet in
            switch sheet {
            case .newFolder:
                NameSheet(title: "Nowy folder", message: "Folder zostanie utworzony w „\(state.activePanel.location.lastPathComponent)”.",
                          initial: "Nowy folder", confirmTitle: "Utwórz") { await state.createFolder(named: $0) }
            case .saveWorkspace:
                NameSheet(title: "Zapisz przestrzeń roboczą",
                          message: "Zapamiętane zostaną karty i lokalizacje obu paneli. Nazwa nie może się powtarzać.",
                          initial: "Przestrzeń \(state.workspaces.count + 1)", confirmTitle: "Zapisz") { state.saveWorkspace(named: $0) }
            case .batchRename(let entries):
                BatchRenameSheet(entries: entries, state: state)
            case .compareFolders:
                CompareSheet(state: state)
            case .duplicates(let root):
                DuplicatesSheet(root: root, state: state)
            case .connections:
                ConnectionsManagerSheet(state: state)
            case .editConnection(let profile):
                ConnectionFormSheet(state: state, existing: profile)
            case .trustedHosts:
                TrustedHostsSheet(state: state)
            case .rename(let entry):
                NameSheet(title: "Zmień nazwę", message: "Nowa nazwa dla „\(entry.name)”.",
                          initial: entry.name, confirmTitle: "Zmień") { await state.rename(entry, to: $0) }
            }
        }
        .connectionPrompts(state, topLevel: true)
        .sheet(item: $state.conflictSheetItem) { pending in
            ConflictSheet(pending: pending, operations: state.operations)
        }
        .confirmationDialog(trashTitle, isPresented: $state.showsTrashDialog, titleVisibility: .visible) {
            Button("Przenieś do Kosza", role: .destructive) { state.confirmTrash() }
            Button("Anuluj", role: .cancel) { state.pendingTrash = [] }
        } message: {
            Text("Elementy trafią do Kosza i będzie można je stamtąd przywrócić (Kosz systemu nie jest opróżniany przez aplikację).")
        }
        .confirmationDialog(remoteDeleteTitle, isPresented: $state.showsRemoteDeleteDialog, titleVisibility: .visible) {
            Button("Usuń z serwera", role: .destructive) { state.confirmRemoteDelete() }
            Button("Anuluj", role: .cancel) { state.pendingRemoteDelete = nil }
        } message: {
            if let r = state.pendingRemoteDelete {
                Text("Serwer: \(r.serverName)\nFolder: \(r.path)\nElementy: \(Polish.items(r.entries.count))\n\nTo NIE jest Kosz — usunięcie na serwerze może być nieodwracalne. Foldery są usuwane razem z zawartością.")
            }
        }
        .alert("Błąd", isPresented: $state.showsAlert) {
            Button("OK", role: .cancel) {}
        } message: { Text(state.alertMessage ?? "") }
    }

    private var remoteDeleteTitle: String {
        guard let r = state.pendingRemoteDelete else { return "" }
        return r.entries.count == 1 ? "Trwale usunąć „\(r.entries[0].name)” z serwera?" : "Trwale usunąć \(Polish.items(r.entries.count)) z serwera?"
    }

    private var trashTitle: String {
        let list = state.pendingTrash
        if list.count == 1 { return "Przenieść „\(list[0].name)” do Kosza?" }
        return "Przenieść \(Polish.items(list.count)) do Kosza?"
    }
}
