import SwiftUI
import AppKit

/// Podmenu „Otwórz za pomocą” z aplikacjami zdolnymi otworzyć plik (najwyżej 20); puste, gdy system nie zna żadnej.
struct OpenWithMenu: View {
    let state: AppState
    let url: URL

    var body: some View {
        let apps = state.applications(toOpen: url)
        if !apps.isEmpty {
            Menu("Otwórz za pomocą") {
                ForEach(Array(apps.prefix(20)), id: \.self) { app in
                    Button(FileManager.default.displayName(atPath: app.path)) { state.open(url, with: app) }
                }
            }
        }
    }
}
