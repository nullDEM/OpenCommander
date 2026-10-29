import Foundation
import Observation

public struct PendingConflict: Identifiable, Equatable {
    public let id = UUID()
    public let jobID: UUID
    public let conflict: Conflict
}

/// Kolejka zadań: wykonuje operacje po jednej, publikuje stan dla interfejsu.
@MainActor @Observable
public final class OperationCenter {
    public struct Job: Identifiable {
        public let id: UUID
        public let operation: FileOperation
        public var state: OperationState = .queued
        public var progress = OperationProgress(completedItems: 0, totalItems: 0, currentItemName: nil)
        public var report: OperationReport?
        public var cancelRequested = false
        public var startedAt: Date?
        public var finishedAt: Date?
        /// Wygładzona prędkość kopiowania (B/s); `nil`, dopóki nie ma wiarygodnej próbki.
        public var bytesPerSecond: Double?
        var lastSampleAt: Date?
        var lastSampleBytes: Int64 = 0

        /// Szacowany czas do końca — tylko gdy znamy prędkość i rozmiar całości.
        public var estimatedRemaining: TimeInterval? {
            guard let speed = bytesPerSecond, speed > 1, let total = progress.totalBytes else { return nil }
            return Double(max(0, total - progress.bytesDone)) / speed
        }

        public func elapsed(at now: Date = Date()) -> TimeInterval {
            guard let start = startedAt else { return 0 }
            return (finishedAt ?? now).timeIntervalSince(start)
        }
    }

    public private(set) var jobs: [Job] = []
    public private(set) var pendingConflict: PendingConflict?

    @ObservationIgnored public var onJobFinished: ((Job) -> Void)?
    @ObservationIgnored private let engine: FileOperationEngine
    @ObservationIgnored private var runningTask: Task<Void, Never>?
    @ObservationIgnored private var runningJobID: UUID?
    @ObservationIgnored private var conflictContinuation: CheckedContinuation<ConflictDecision, Never>?

    public init(trasher: any Trashing = SystemTrasher(), journal: TempJournal? = nil, remote: (any RemoteOperationHandling)? = nil) {
        self.engine = FileOperationEngine(trasher: trasher, journal: journal, remote: remote)
    }

    init(engine: FileOperationEngine) {
        self.engine = engine
    }

    public var hasActiveJobs: Bool { jobs.contains { !$0.state.isFinished } }

    public func enqueue(_ operation: FileOperation) {
        var job = Job(id: operation.id, operation: operation)
        job.progress.totalItems = operation.sources.count
        jobs.append(job)
        startNextIfIdle()
    }

    public func cancel(_ jobID: UUID) {
        guard let idx = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        switch jobs[idx].state {
        case .queued:
            jobs[idx].state = .cancelled
        case .running, .awaitingDecision:
            jobs[idx].cancelRequested = true
            runningTask?.cancel()
            if let cont = conflictContinuation {
                conflictContinuation = nil
                pendingConflict = nil
                cont.resume(returning: ConflictDecision(.skip))
            }
        default:
            break
        }
    }

    public func resolveConflict(_ decision: ConflictDecision) {
        guard let cont = conflictContinuation else { return }
        conflictContinuation = nil
        pendingConflict = nil
        if let id = runningJobID, let idx = jobs.firstIndex(where: { $0.id == id }) {
            jobs[idx].state = .running
            // Czas oczekiwania na decyzję nie może zaburzyć prędkości.
            jobs[idx].lastSampleAt = Date()
            jobs[idx].lastSampleBytes = jobs[idx].progress.bytesDone
        }
        cont.resume(returning: decision)
    }

    /// Ręczne ponowienie nieudanych elementów zadania — **od początku** (bez wznawiania): każdy ponawiany element
    /// jest przesyłany lub usuwany od nowa. Zadanie wraca do kolejki jako nowe.
    @discardableResult
    public func retryFailed(_ jobID: UUID) -> Bool {
        guard let job = jobs.first(where: { $0.id == jobID }), job.state.isFinished,
              let report = job.report else { return false }
        let failed = report.failures.map(\.0)
        guard !failed.isEmpty else { return false }
        enqueue(FileOperation(kind: job.operation.kind, sources: failed, destination: job.operation.destination))
        return true
    }

    public func clearFinished() {
        jobs.removeAll { $0.state.isFinished }
    }

    /// Czeka na zakończenie wszystkich zadań (głównie testy).
    public func waitUntilIdle() async {
        while hasActiveJobs { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    // MARK: - Wewnętrzne

    private func startNextIfIdle() {
        guard runningTask == nil, let idx = jobs.firstIndex(where: { $0.state == .queued }) else { return }
        let job = jobs[idx]
        jobs[idx].state = .running
        jobs[idx].startedAt = Date()
        runningJobID = job.id
        let engine = self.engine
        runningTask = Task { [weak self] in
            let report = await engine.run(
                job.operation,
                conflictHandler: { [weak self] conflict in
                    guard let self else { return ConflictDecision(.skip) }
                    return await self.askUser(conflict, jobID: job.id)
                },
                progress: { [weak self] p in
                    Task { @MainActor in self?.updateProgress(job.id, p) }
                }
            )
            self?.finish(job.id, report)
        }
    }

    private func askUser(_ conflict: Conflict, jobID: UUID) async -> ConflictDecision {
        if Task.isCancelled { return ConflictDecision(.skip) }
        return await withCheckedContinuation { cont in
            conflictContinuation = cont
            pendingConflict = PendingConflict(jobID: jobID, conflict: conflict)
            if let idx = jobs.firstIndex(where: { $0.id == jobID }) { jobs[idx].state = .awaitingDecision }
        }
    }

    private func updateProgress(_ id: UUID, _ p: OperationProgress) {
        guard let idx = jobs.firstIndex(where: { $0.id == id }), !jobs[idx].state.isFinished else { return }
        // Zadania aktualizacji mogą dotrzeć nie po kolei — nie cofamy postępu.
        let old = jobs[idx].progress
        guard p.completedItems > old.completedItems || (p.completedItems == old.completedItems && p.bytesDone >= old.bytesDone) else { return }
        jobs[idx].progress = p
        let now = Date()
        guard let last = jobs[idx].lastSampleAt else {
            jobs[idx].lastSampleAt = now; jobs[idx].lastSampleBytes = p.bytesDone; return
        }
        let dt = now.timeIntervalSince(last)
        if dt >= 0.5 {
            let instant = Double(p.bytesDone - jobs[idx].lastSampleBytes) / dt
            let old = jobs[idx].bytesPerSecond
            jobs[idx].bytesPerSecond = old.map { 0.6 * $0 + 0.4 * instant } ?? instant
            jobs[idx].lastSampleAt = now
            jobs[idx].lastSampleBytes = p.bytesDone
        }
    }

    private func finish(_ id: UUID, _ report: OperationReport) {
        guard let idx = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[idx].report = report
        jobs[idx].finishedAt = Date()
        let handled = report.results.filter { $0.outcome != .cancelled }.count
        jobs[idx].progress.completedItems = handled
        jobs[idx].progress.currentItemName = nil
        if report.cancelledCount == 0, !jobs[idx].cancelRequested, let total = jobs[idx].progress.totalBytes {
            jobs[idx].progress.bytesDone = total
        }
        if jobs[idx].cancelRequested || report.cancelledCount > 0 {
            jobs[idx].state = .cancelled
        } else if report.failures.isEmpty {
            jobs[idx].state = .completed
        } else if report.completedCount == 0 {
            jobs[idx].state = .failed
        } else {
            jobs[idx].state = .completedWithIssues
        }
        runningTask = nil
        runningJobID = nil
        onJobFinished?(jobs[idx])
        startNextIfIdle()
    }
}
