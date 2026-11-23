import SwiftUI
import AppKit
import OpenCommanderCore

struct JobRow: View, Equatable {
    let job: OperationCenter.Job
    let ops: OperationCenter

    /// Ile błędów pokazujemy w wierszu — pełna lista może mieć tysiące pozycji (np. folder bez uprawnień).
    private static let maxShownFailures = 20

    /// Widok zależy od tych pól zadania; reszta (operacja, znaczniki próbkowania) nie zmienia wyglądu.
    static func == (a: JobRow, b: JobRow) -> Bool {
        a.job.id == b.job.id && a.job.state == b.job.state && a.job.progress == b.job.progress
            && a.job.bytesPerSecond == b.job.bytesPerSecond && a.job.startedAt == b.job.startedAt
            && a.job.finishedAt == b.job.finishedAt && a.job.report?.results.count == b.job.report?.results.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(color)
                Text(job.operation.title).font(.callout).lineLimit(1)
                Spacer()
                Text(statusText).font(.caption).foregroundStyle(.secondary)
                if !job.state.isFinished {
                    Button { ops.cancel(job.id) } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.borderless).help("Anuluj").accessibilityLabel("Anuluj operację")
                }
            }
            if job.state == .running || job.state == .awaitingDecision {
                progressSection
            }
            if let report = job.report {
                let failures = report.failures
                ForEach(Array(failures.prefix(Self.maxShownFailures).enumerated()), id: \.offset) { _, failure in
                    Text(failure.1.localizedDescription).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    if failure.1.isAccessDenied, failure.0.isFileURL {
                        HStack(spacing: 10) {
                            Button("Pokaż w Finderze") { NSWorkspace.shared.activateFileViewerSelecting([failure.0]) }
                            Button("Otwórz ustawienia prywatności") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            Button("Ustawienia Automatyzacji") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                        }
                        .font(.caption).buttonStyle(.link)
                    }
                }
                if failures.count > Self.maxShownFailures {
                    Text("…oraz \(failures.count - Self.maxShownFailures) kolejnych błędów (nie wyświetlono ich wszystkich).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if job.state.isFinished, !report.failures.isEmpty, job.state != .cancelled {
                    Button("Ponów nieudane od początku") { ops.retryFailed(job.id) }
                        .font(.caption).buttonStyle(.link)
                        .help("Ponawia tylko nieudane elementy, każdy od początku (bez wznawiania). Nic nie jest ponawiane automatycznie.")
                }
            }
        }
    }

    /// Pasek na żywo: bajty (gdy mierzone), prędkość, upłynęły czas i szacowany czas do końca.
    private var progressSection: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 2) {
                if let fraction = job.progress.byteFraction {
                    ProgressView(value: fraction).controlSize(.small)
                        .accessibilityLabel("Postęp kopiowania")
                        .accessibilityValue("\(Int(fraction * 100)) procent")
                } else {
                    ProgressView(value: Double(job.progress.completedItems), total: Double(max(job.progress.totalItems, 1)))
                        .controlSize(.small)
                        .accessibilityLabel("Postęp: \(job.progress.completedItems) z \(Polish.items(job.progress.totalItems))")
                }
                HStack(spacing: 8) {
                    if let name = job.progress.currentItemName {
                        Text(name).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    Text(details(at: context.date)).monospacedDigit().lineLimit(1)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func details(at now: Date) -> String {
        var parts: [String] = []
        if let total = job.progress.totalBytes, total > 0 {
            let done = ProgressFormat.bytes(job.progress.bytesDone)
            parts.append("\(done) z \(ProgressFormat.bytes(total))")
            if job.state == .running, let speed = job.bytesPerSecond, speed > 1 {
                parts.append("\(ProgressFormat.bytes(Int64(speed)))/s")
            }
        }
        parts.append("czas: \(ProgressFormat.clock(job.elapsed(at: now)))")
        if job.state == .running, let eta = job.estimatedRemaining {
            parts.append("zostało ok. \(ProgressFormat.duration(eta))")
        }
        return parts.joined(separator: " · ")
    }

    private var statusText: String {
        switch job.state {
        case .queued: return "w kolejce"
        case .running: return "\(job.progress.completedItems) z \(Polish.items(job.progress.totalItems))"
        case .awaitingDecision: return "czeka na decyzję"
        case .completed: return "gotowe w \(ProgressFormat.clock(job.elapsed())) (\(job.report?.summary ?? ""))"
        case .completedWithIssues: return "zakończono z błędami (\(job.report?.summary ?? ""))"
        case .failed: return "nie powiodło się"
        case .cancelled: return "anulowano (\(job.report?.summary ?? "nic nie wykonano"))"
        }
    }

    private var icon: String {
        switch job.state {
        case .queued: return "clock"
        case .running: return "arrow.triangle.2.circlepath"
        case .awaitingDecision: return "questionmark.circle"
        case .completed: return "checkmark.circle.fill"
        case .completedWithIssues: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.octagon.fill"
        case .cancelled: return "minus.circle"
        }
    }

    private var color: Color {
        switch job.state {
        case .completed: return .green
        case .completedWithIssues: return .orange
        case .failed: return .red
        default: return .secondary
        }
    }
}
