import SwiftUI
import AppKit
import OpenCommanderCore

/// Zwijany obszar kolejki operacji. Postęp jest liczony w elementach, nie w bajtach.
struct OperationsBar: View {
    let state: AppState

    var body: some View {
        let ops = state.operations
        if !ops.jobs.isEmpty {
            VStack(spacing: 0) {
                Divider()
                HStack {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { state.operationsExpanded.toggle() }
                    } label: {
                        Label("Operacje (\(ops.jobs.count))", systemImage: state.operationsExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(state.operationsExpanded ? "Zwiń operacje" : "Rozwiń operacje")
                    Spacer()
                    if ops.jobs.contains(where: { $0.state.isFinished }) {
                        Button("Wyczyść zakończone") { ops.clearFinished() }.font(.caption).buttonStyle(.link)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 4)

                if state.operationsExpanded {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(ops.jobs.reversed()) { job in
                                // `.equatable()`: kolejny tik postępu jednego zadania nie przerysowuje pozostałych (np. zakończonych z listą błędów).
                                JobRow(job: job, ops: ops).equatable()
                                    .padding(8)
                                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
                            }
                        }
                        .padding(.horizontal, 10).padding(.bottom, 8)
                    }
                    .frame(maxHeight: 190)
                }
            }
            .background(.bar)
        }
    }
}
