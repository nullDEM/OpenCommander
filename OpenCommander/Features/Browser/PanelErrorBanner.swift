import SwiftUI
import OpenCommanderCore

/// Baner błędu ładowania folderu z przyciskiem ponowienia.
struct PanelErrorBanner: View {
    let error: OperationError
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(error.localizedDescription).font(.callout).lineLimit(2)
            Spacer()
            Button("Ponów", action: onRetry)
        }
        .padding(8)
        .background(Color.orange.opacity(0.12))
    }
}
