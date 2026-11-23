import SwiftUI
import OpenCommanderCore

/// Konflikt nazw: pomiń / zachowaj obie / zastąp. Zastąpienie nigdy nie jest domyślne.
struct ConflictSheet: View {
    let pending: PendingConflict
    let operations: OperationCenter
    @State private var applyToAll = false

    var body: some View {
        let c = pending.conflict
        VStack(alignment: .leading, spacing: 12) {
            Label("Element o tej nazwie już istnieje", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
            Text("W folderze docelowym znajduje się już „\(c.existing.lastPathComponent)”.")
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                GridRow { Text("Nowy (źródło)").font(.caption.weight(.semibold)); Text(Self.describe(c.source)) }
                GridRow { Text("Istniejący").font(.caption.weight(.semibold)); Text(Self.describe(c.existing)) }
            }
            .font(.callout).foregroundStyle(.secondary)
            Text(c.existing.remoteLocation.map { "Serwer: " + $0.parent.path.string } ?? c.existing.deletingLastPathComponent().path)
                .font(.caption).foregroundStyle(.tertiary).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
            Toggle("Zastosuj do wszystkich kolejnych konfliktów w tej operacji", isOn: $applyToAll)
            if c.existing.isRemoteLocation {
                Text("„Zastąp” nadpisze plik NA SERWERZE — serwer nie ma Kosza, więc starej wersji nie da się stamtąd przywrócić.")
                    .font(.caption).foregroundStyle(.orange)
            } else {
                Text("„Zastąp” przenosi istniejący element do Kosza.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Anuluj operację", role: .cancel) { operations.cancel(pending.jobID) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Pomiń") { operations.resolveConflict(ConflictDecision(.skip, applyToAll: applyToAll)) }
                Button("Zachowaj obie") { operations.resolveConflict(ConflictDecision(.keepBoth, applyToAll: applyToAll)) }
                    .keyboardShortcut(.defaultAction)
                Button("Zastąp…", role: .destructive) { operations.resolveConflict(ConflictDecision(.replace, applyToAll: applyToAll)) }
            }
        }
        .padding(20)
        .frame(width: 480)
        .interactiveDismissDisabled()
    }

    private static func describe(_ url: URL) -> String {
        guard url.isFileURL else { return "na serwerze" }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return "niedostępny" }
        let isDir = (attrs[.type] as? FileAttributeType) == .typeDirectory
        let size = isDir ? "folder" : ProgressFormat.bytes((attrs[.size] as? NSNumber)?.int64Value ?? 0)
        let date = (attrs[.modificationDate] as? Date).map { ModifiedDateText.string(for: $0) } ?? "—"
        return "\(size) · \(date)"
    }
}
