import SwiftUI

@main
struct OpenCommanderApp: App {
    @State private var state = AppState()

    var body: some Scene {
        Window("OpenCommander", id: "main") {
            RootView(state: state)
                .frame(minWidth: 900, minHeight: 460) // pasek boczny 150 + 2 panele po 250 + panel informacji 220 = 870
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    state.persist()
                }
        }
        .defaultSize(width: 1200, height: 720)
        .commands { AppCommands(state: state) }

        Window("Skróty klawiszowe", id: "shortcuts") {
            ShortcutsView()
        }
        .defaultSize(width: 620, height: 640)
    }
}
