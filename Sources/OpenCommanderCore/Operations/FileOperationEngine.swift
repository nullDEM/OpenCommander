import AppKit
import Foundation

/// Przenoszenie do Kosza jako zależność — w testach podmieniane, by nie ruszać prawdziwego Kosza.
public protocol Trashing: Sendable {
    func trash(_ url: URL) async throws
}

public struct SystemTrasher: Trashing {
    public init() {}

    public func trash(_ url: URL) async throws {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            // Przy odmowie dostępu (np. plik z `com.apple.macl` na Pulpicie iCloud) próbujemy dalszych dróg systemowych;
            // gdy wszystkie zawiodą, zgłaszamy pierwotny błąd. Inne błędy (np. brak pliku) nie są ponawiane.
            guard case .permissionDenied = OperationError.map(error, item: url.lastPathComponent) else { throw error }
            if await Self.recycleViaWorkspace(url) { return }
            if await Self.trashViaFinder(url) { return }
            throw error
        }
    }

    /// `NSWorkspace.recycle` działa przez system (nie tylko przez uprawnienia procesu). Bez blokowania wątku; limit czasu 30 s.
    private static func recycleViaWorkspace(_ url: URL) async -> Bool {
        await withCheckedContinuation { cont in
            let once = ResumeOnce()
            NSWorkspace.shared.recycle([url]) { trashed, error in
                let ok = error == nil && !trashed.isEmpty
                once.run { cont.resume(returning: ok) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 30) { once.run { cont.resume(returning: false) } }
        }
    }

    /// Ostatnia droga: prosimy Finder (ma własne uprawnienia do chronionych plików) o przeniesienie do Kosza — nie o trwałe usunięcie.
    /// Tylko dla woluminów lokalnych: na dysku sieciowym bez Kosza Finder mógłby usunąć element bezpowrotnie.
    /// Wymaga zgody użytkownika na automatyzację Findera; sukces uznajemy dopiero, gdy pliku nie ma już w dotychczasowym miejscu.
    private static func trashViaFinder(_ url: URL) async -> Bool {
        guard isOnLocalVolume(url) else { return false }
        let source = finderTrashScript(for: url)
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                var errorInfo: NSDictionary?
                _ = NSAppleScript(source: source)?.executeAndReturnError(&errorInfo)
                cont.resume(returning: errorInfo == nil && !FileManager.default.fileExists(atPath: url.path))
            }
        }
    }

    /// Wolumin lokalny (wewnętrzny lub podłączony do tego Maca). Gdy nie da się ustalić — traktujemy jak nielokalny.
    static func isOnLocalVolume(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) ?? false
    }

    /// Skrypt dla Findera: `delete` przenosi do Kosza. Ścieżka trafia do literału tekstowego, więc `\` i `"` są poprzedzane ukośnikiem.
    static func finderTrashScript(for url: URL) -> String {
        let escaped = url.path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "tell application \"Finder\" to delete POSIX file \"\(escaped)\""
    }

    /// Wykonuje akcję najwyżej raz (wynik albo limit czasu — co nastąpi pierwsze).
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func run(_ action: () -> Void) {
            let first = lock.withLock { () -> Bool in
                if done { return false }
                done = true
                return true
            }
            if first { action() }
        }
    }
}

/// Wykonuje kopiowanie, przenoszenie i przenoszenie do Kosza.
///
/// Zasady bezpieczeństwa:
/// - kopia powstaje pod nazwą tymczasową w folderze docelowym i dopiero po sukcesie dostaje właściwą nazwę;
/// - nic nie jest nadpisywane bez jawnej decyzji `.replace`; zastępowany element trafia do Kosza;
/// - źródło przenoszone między wolumenami jest usuwane dopiero po pomyślnej kopii;
/// - dowiązania symboliczne są kopiowane jako dowiązania (nie są rozwijane).
public struct FileOperationEngine: Sendable {
    public typealias ConflictHandler = @Sendable (Conflict) async -> ConflictDecision
    public typealias ProgressHandler = @Sendable (OperationProgress) -> Void

    let trasher: any Trashing
    /// Tylko do testów: traktuj każde przenoszenie jak międzywolumenowe (kopia + usunięcie źródła).
    let forceCrossVolumeMove: Bool
    /// Tylko do testów: wyłącza klonowanie APFS, by kopiowanie faktycznie przesyłało dane.
    let allowClone: Bool
    /// Minimalny odstęp między raportami postępu bajtowego.
    let progressInterval: TimeInterval
    let journal: TempJournal?
    /// Obsługa operacji na serwerach zdalnych (SFTP/FTP/WebDAV). Bez niej operacje zdalne kończą się błędem.
    let remote: (any RemoteOperationHandling)?

    public init(trasher: any Trashing = SystemTrasher(), journal: TempJournal? = nil, remote: (any RemoteOperationHandling)? = nil) {
        self.init(trasher: trasher, forceCrossVolumeMove: false, journal: journal, remote: remote)
    }

    init(trasher: any Trashing, forceCrossVolumeMove: Bool = false, allowClone: Bool = true,
         progressInterval: TimeInterval = 0.1, journal: TempJournal? = nil, remote: (any RemoteOperationHandling)? = nil) {
        self.remote = remote
        self.journal = journal
        self.trasher = trasher
        self.forceCrossVolumeMove = forceCrossVolumeMove
        self.allowClone = allowClone
        self.progressInterval = progressInterval
    }

    public func run(_ op: FileOperation,
                    conflictHandler: @escaping ConflictHandler = { _ in ConflictDecision(.skip) },
                    progress: @escaping ProgressHandler = { _ in }) async -> OperationReport {
        if op.involvesRemote || op.kind == .delete {
            guard let remote else {
                return OperationReport(results: op.sources.map {
                    ItemResult(source: $0, outcome: .failed(.other(name: $0.lastPathComponent, reason: "obsługa serwerów zdalnych nie jest dostępna.")))
                })
            }
            return await remote.run(op, conflictHandler: conflictHandler, progress: progress)
        }
        var results: [ItemResult] = []
        var sticky: ConflictResolution?
        let total = op.sources.count
        let sizes: [Int64] = op.kind == .trash ? [] : op.sources.map { FileCopier.totalBytes(of: $0) }
        let reporter = ProgressReporter(totalItems: total,
                                        totalBytes: op.kind == .trash ? nil : sizes.reduce(0, +),
                                        interval: progressInterval, sink: progress)

        for (index, source) in op.sources.enumerated() {
            reporter.begin(index: index, name: source.lastPathComponent, size: op.kind == .trash ? 0 : sizes[index])
            // Anulowanie sprawdzamy tuż przed pracą nad elementem.
            if Task.isCancelled {
                results += op.sources[index...].map { ItemResult(source: $0, outcome: .cancelled) }
                break
            }
            let outcome: ItemOutcome
            switch op.kind {
            case .trash:
                outcome = await trash(source)
            case .delete:
                outcome = .failed(.other(name: source.lastPathComponent, reason: "usuwanie trwałe jest dostępne tylko na serwerach zdalnych."))
            case .copy, .move:
                if let dest = op.destination {
                    outcome = await transfer(source, kind: op.kind, into: dest, handler: conflictHandler,
                                             sticky: &sticky, reporter: reporter)
                } else {
                    outcome = .failed(.destinationUnavailable("?"))
                }
            }
            if outcome != .cancelled { reporter.finishItem() }
            results.append(ItemResult(source: source, outcome: outcome))
        }
        reporter.emitFinal()
        return OperationReport(results: results)
    }

    // MARK: - Kosz

    private func trash(_ url: URL) async -> ItemOutcome {
        let name = url.lastPathComponent
        guard Self.exists(url) else { return .failed(.sourceMissing(name)) }
        do {
            try await trasher.trash(url)
            return .completed(nil)
        } catch {
            return .failed(OperationError.trash(error, name: name))
        }
    }

    // MARK: - Kopiowanie / przenoszenie

    private func transfer(_ source: URL, kind: OperationKind, into destDir: URL,
                          handler: ConflictHandler, sticky: inout ConflictResolution?,
                          reporter: ProgressReporter) async -> ItemOutcome {
        let fm = FileManager.default
        let name = source.lastPathComponent
        guard let attrs = try? fm.attributesOfItem(atPath: source.path) else { return .failed(.sourceMissing(name)) }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: destDir.path, isDirectory: &isDir), isDir.boolValue else {
            return .failed(.destinationUnavailable(destDir.lastPathComponent))
        }

        let isRealDirectory = (attrs[.type] as? FileAttributeType) == .typeDirectory
        let srcParentReal = source.deletingLastPathComponent().resolvingSymlinksInPath().path
        let destReal = destDir.resolvingSymlinksInPath().path
        let srcReal = (srcParentReal as NSString).appendingPathComponent(name)

        if isRealDirectory && Self.isInside(destReal, of: srcReal) { return .failed(.copyIntoItself(name)) }
        if kind == .move && Self.samePath(srcParentReal, destReal) { return .skipped("element jest już w tym folderze") }

        var finalTarget = destDir.appendingPathComponent(name)
        var replacing = false
        if Self.exists(finalTarget) {
            let resolution: ConflictResolution
            if let sticky {
                resolution = sticky
            } else {
                let decision = await handler(Conflict(source: source, existing: finalTarget))
                if decision.applyToAll { sticky = decision.resolution }
                resolution = decision.resolution
            }
            switch resolution {
            case .skip:
                return .skipped("konflikt nazw — pominięto")
            case .keepBoth:
                finalTarget = Self.uniqueURL(for: finalTarget, like: source)
            case .replace:
                let targetReal = (destReal as NSString).appendingPathComponent(name)
                if Self.samePath(targetReal, srcReal) || Self.isInside(srcReal, of: targetReal) {
                    return .failed(.replaceWouldDestroySource(name))
                }
                replacing = true
            }
        }

        let sameVolume = !forceCrossVolumeMove && Self.sameVolume(source, destDir)
        let renameBased = (kind == .move && sameVolume)
        let tmp = destDir.appendingPathComponent("\(TempJournal.tempPrefix)\(UUID().uuidString)")
        // Zapis w dzienniku przed pierwszą zmianą na dysku — umożliwia sprzątanie/odzysk po awarii.
        journal?.register(.init(tmp: tmp.path, kind: renameBased ? .movedSource : .copy,
                                original: renameBased ? source.path : nil))
        defer { journal?.unregister(tmpPath: tmp.path) }

        // Rollback dotyczy wyłącznie naszego pliku tymczasowego.
        func rollback() {
            if renameBased { try? fm.moveItem(at: tmp, to: source) } else { try? fm.removeItem(at: tmp) }
        }

        do {
            if renameBased {
                try fm.moveItem(at: source, to: tmp)
            } else {
                try FileCopier.copy(from: source, to: tmp, allowClone: allowClone) { reporter.itemBytes($0) }
            }
        } catch is CancellationError {
            try? fm.removeItem(at: tmp) // przerwana kopia: sprzątamy tylko własny plik tymczasowy
            return .cancelled
        } catch {
            if !renameBased { try? fm.removeItem(at: tmp) }
            return .failed(OperationError.map(error, item: name))
        }

        if replacing {
            do { try await trasher.trash(finalTarget) } catch {
                rollback()
                return .failed(OperationError.trash(error, name: finalTarget.lastPathComponent))
            }
        }

        do {
            try fm.moveItem(at: tmp, to: finalTarget)
        } catch {
            rollback()
            let base = OperationError.map(error, item: name)
            if replacing {
                // Zastępowany element jest już w Koszu — rollback go stamtąd nie wyjmuje, więc mówimy to wprost.
                return .failed(.other(name: name, reason: "\(base.localizedDescription) Poprzedni element „\(finalTarget.lastPathComponent)” został już przeniesiony do Kosza — możesz go stamtąd przywrócić."))
            }
            return .failed(base)
        }

        if kind == .move && !renameBased {
            do { try fm.removeItem(at: source) } catch {
                return .failed(.sourceNotRemoved(name: name, reason: (error as NSError).localizedDescription))
            }
        }
        return .completed(finalTarget)
    }

    // MARK: - Pomocnicze

    static func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    static func samePath(_ a: String, _ b: String) -> Bool {
        a.precomposedStringWithCanonicalMapping.lowercased() == b.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// Czy `path` leży w `container` albo jest nim (porównanie zachowawcze: bez rozróżniania wielkości liter).
    static func isInside(_ path: String, of container: String) -> Bool {
        let p = path.precomposedStringWithCanonicalMapping.lowercased()
        let c = container.precomposedStringWithCanonicalMapping.lowercased()
        return p == c || p.hasPrefix(c.hasSuffix("/") ? c : c + "/")
    }

    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let va = try? a.deletingLastPathComponent().resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        let vb = try? b.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        guard let x = va as? NSObject, let y = vb as? NSObject else { return false }
        return x.isEqual(y)
    }

    /// „nazwa kopia.ext”, „nazwa kopia 2.ext”, …
    static func uniqueURL(for target: URL, like source: URL) -> URL {
        let dir = target.deletingLastPathComponent()
        let isPackage = (try? source.resourceValues(forKeys: [.isPackageKey]).isPackage) ?? false
        let isDir = (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        let splitExtension = !isDir || isPackage
        let ext = splitExtension ? target.pathExtension : ""
        let base = ext.isEmpty ? target.lastPathComponent : target.deletingPathExtension().lastPathComponent
        var n = 1
        while true {
            let suffix = n == 1 ? " kopia" : " kopia \(n)"
            let name = base + suffix + (ext.isEmpty ? "" : ".\(ext)")
            let candidate = dir.appendingPathComponent(name)
            if !exists(candidate) { return candidate }
            n += 1
        }
    }
}

/// Zbiera i dławi (throttle) raporty postępu. Wywoływany synchronicznie z wątku wykonującego kopię.
final class ProgressReporter {
    private let totalItems: Int
    private let totalBytes: Int64?
    private let interval: TimeInterval
    private let sink: FileOperationEngine.ProgressHandler
    private var completedItems = 0
    private var baseBytes: Int64 = 0
    private var itemSize: Int64 = 0
    private var currentName: String?
    private var lastEmit: CFAbsoluteTime = 0

    init(totalItems: Int, totalBytes: Int64?, interval: TimeInterval, sink: @escaping FileOperationEngine.ProgressHandler) {
        self.totalItems = totalItems
        self.totalBytes = totalBytes
        self.interval = interval
        self.sink = sink
    }

    func begin(index: Int, name: String, size: Int64) {
        completedItems = index
        currentName = name
        itemSize = size
        emit(inflight: 0)
    }

    func itemBytes(_ done: Int64) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastEmit >= interval else { return }
        emit(inflight: min(done, itemSize))
    }

    func finishItem() {
        baseBytes += itemSize
        completedItems += 1
        itemSize = 0
        emit(inflight: 0)
    }

    func emitFinal() {
        currentName = nil
        emit(inflight: 0)
    }

    private func emit(inflight: Int64) {
        lastEmit = CFAbsoluteTimeGetCurrent()
        sink(OperationProgress(completedItems: completedItems, totalItems: totalItems, currentItemName: currentName,
                               bytesDone: baseBytes + inflight, totalBytes: totalBytes))
    }
}
