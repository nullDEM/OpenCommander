import Foundation

/// Wykonuje operacje, w których występuje serwer zdalny. Podpinany do `FileOperationEngine`, więc korzysta z tej samej
/// kolejki, dialogu konfliktów i raportów co operacje lokalne.
public protocol RemoteOperationHandling: Sendable {
    func run(_ op: FileOperation,
             conflictHandler: @escaping FileOperationEngine.ConflictHandler,
             progress: @escaping FileOperationEngine.ProgressHandler) async -> OperationReport
}

/// Silnik transferów lokalny ↔ serwer.
///
/// Zasady bezpieczeństwa:
/// - tylko **kopiowanie** (upload/download) i trwałe usuwanie na serwerze; nie ma przenoszenia ani transferów serwer → serwer;
/// - lokalne źródło nigdy nie jest usuwane po uploadzie;
/// - pobieranie idzie do pliku/folderu tymczasowego (`.opencommander-tmp-…`, w dzienniku `TempJournal`) i dopiero po sukcesie
///   (sprawdzenie rozmiaru) dostaje właściwą nazwę — przerwane pobranie nie wygląda jak kompletny plik;
/// - upload idzie pod nazwą tymczasową na serwerze i jest zmieniany na finalną (tam, gdzie serwer wspiera rename; atomowość NIE jest gwarantowana);
/// - nazwy z serwera są niezaufane: nazwy wychodzące poza katalog docelowy są blokowane;
/// - zdalne dowiązania symboliczne nie są rozwijane; zastąpienie folderu na serwerze jest zabronione;
/// - żadna operacja nie jest ponawiana automatycznie.
public struct RemoteTransferEngine: RemoteOperationHandling {
    public typealias ProviderResolver = @Sendable (UUID) async throws -> any FileProvider

    let providerFor: ProviderResolver
    let trasher: any Trashing
    let journal: TempJournal?
    static let tempPrefix = TempJournal.tempPrefix
    static let maxDepth = 64

    public init(providerFor: @escaping ProviderResolver, trasher: any Trashing = SystemTrasher(), journal: TempJournal? = nil) {
        self.providerFor = providerFor
        self.trasher = trasher
        self.journal = journal
    }

    // MARK: - Wejście

    public func run(_ op: FileOperation,
                    conflictHandler: @escaping FileOperationEngine.ConflictHandler,
                    progress: @escaping FileOperationEngine.ProgressHandler) async -> OperationReport {
        let meter = Meter(totalItems: op.sources.count, sink: progress)
        var ctx = Context(conflict: conflictHandler, meter: meter)
        var results: [ItemResult] = []

        func failAll(_ reason: String) -> OperationReport {
            OperationReport(results: op.sources.map { ItemResult(source: $0, outcome: .failed(.other(name: $0.lastPathComponent, reason: reason))) })
        }

        switch op.kind {
        case .move:
            return failAll("przenoszenie między komputerem a serwerem nie jest obsługiwane — użyj kopiowania.")
        case .trash:
            return failAll("na serwerze nie ma Kosza — użyj „Usuń na serwerze”, które jest nieodwracalne.")
        case .delete:
            guard op.sources.allSatisfy(\.isRemoteLocation) else { return failAll("usuwanie trwałe dotyczy tylko zasobów na serwerze.") }
            for (i, src) in op.sources.enumerated() {
                if Task.isCancelled { results += op.sources[i...].map { ItemResult(source: $0, outcome: .cancelled) }; break }
                meter.begin(index: i, name: src.lastPathComponent)
                let outcome = await deleteItem(src)
                if outcome != .cancelled { meter.finishItem() }
                results.append(ItemResult(source: src, outcome: outcome))
            }
        case .copy:
            guard let dest = op.destination else { return failAll("nie wskazano folderu docelowego.") }
            if dest.isRemoteLocation {
                guard op.sources.allSatisfy({ $0.isFileURL }) else {
                    return failAll("transfery serwer → serwer są wyłączone — pobierz najpierw na komputer.")
                }
                meter.totalBytes = op.sources.reduce(Int64(0)) { $0 + FileCopier.totalBytes(of: $1) }
            } else {
                guard dest.isFileURL, op.sources.allSatisfy(\.isRemoteLocation) else {
                    return failAll("nieobsługiwana kombinacja źródła i celu.")
                }
            }
            for (i, src) in op.sources.enumerated() {
                if Task.isCancelled { results += op.sources[i...].map { ItemResult(source: $0, outcome: .cancelled) }; break }
                meter.begin(index: i, name: src.lastPathComponent)
                let outcome: ItemOutcome = dest.isRemoteLocation
                    ? await uploadItem(src, into: dest, ctx: &ctx)
                    : await downloadItem(src, into: dest, ctx: &ctx)
                if outcome != .cancelled { meter.finishItem() }
                results.append(ItemResult(source: src, outcome: outcome))
            }
        }
        meter.emitFinal()
        return OperationReport(results: results)
    }

    // MARK: - Kontekst i postęp

    struct Context {
        let conflict: FileOperationEngine.ConflictHandler
        let meter: Meter
        var sticky: ConflictResolution?
    }

    /// Zbiera postęp: bajty bieżącego pliku + zsumowane dotychczasowe. Wołany z wątków providerów — stąd blokada.
    final class Meter: @unchecked Sendable {
        private let lock = NSLock()
        private let totalItems: Int
        private let sink: FileOperationEngine.ProgressHandler
        var totalBytes: Int64?
        private var completed = 0
        private var name: String?
        private var base: Int64 = 0
        private var inflight: Int64 = 0
        private var lastEmit: CFAbsoluteTime = 0

        init(totalItems: Int, sink: @escaping FileOperationEngine.ProgressHandler) { self.totalItems = totalItems; self.sink = sink }

        func begin(index: Int, name: String) { lock.withLock { completed = index; self.name = name; inflight = 0 }; emit(force: true) }
        func fileProgress(_ done: Int64) { lock.withLock { inflight = done }; emit(force: false) }
        func fileFinished(size: Int64) { lock.withLock { base += size; inflight = 0 } }
        func finishItem() { lock.withLock { completed += 1; inflight = 0 }; emit(force: true) }
        func emitFinal() { lock.withLock { name = nil; inflight = 0 }; emit(force: true) }

        private func emit(force: Bool) {
            let snap: OperationProgress? = lock.withLock {
                let now = CFAbsoluteTimeGetCurrent()
                guard force || now - lastEmit >= 0.1 else { return nil }
                lastEmit = now
                return OperationProgress(completedItems: completed, totalItems: totalItems, currentItemName: name,
                                         bytesDone: base + inflight, totalBytes: totalBytes)
            }
            if let snap { sink(snap) }
        }
    }

    // MARK: - Mapowanie błędów

    static func outcomeError(_ error: Error, name: String) -> ItemOutcome {
        if error is CancellationError { return .cancelled }
        if let n = error as? NetworkError {
            if n == .cancelled { return .cancelled }
            return .failed(.other(name: name, reason: Redactor.redact(n.localizedDescription)))
        }
        if let o = error as? OperationError { return .failed(o) }
        return .failed(OperationError.map(error, item: name))
    }

    // MARK: - Konflikty

    private func resolve(source: URL, existing: URL, ctx: inout Context) async -> ConflictResolution {
        if let s = ctx.sticky { return s }
        let d = await ctx.conflict(Conflict(source: source, existing: existing))
        if d.applyToAll { ctx.sticky = d.resolution }
        return d.resolution
    }

    /// „nazwa kopia.ext”, „nazwa kopia 2.ext”… — wolna nazwa na serwerze (sprawdzana przez `stat`).
    private func uniqueRemoteName(_ name: String, isDirectory: Bool, in dir: RemotePath, provider: any FileProvider) async throws -> String {
        let ns = name as NSString
        let ext = isDirectory ? "" : ns.pathExtension
        let base = ext.isEmpty ? name : ns.deletingPathExtension
        var n = 1
        while n < 10_000 {
            let candidate = base + (n == 1 ? " kopia" : " kopia \(n)") + (ext.isEmpty ? "" : ".\(ext)")
            if try await provider.stat(try dir.appending(candidate)) == nil { return candidate }
            n += 1
        }
        throw NetworkError.conflict(name)
    }

    // MARK: - Upload

    private func uploadItem(_ source: URL, into destDir: URL, ctx: inout Context) async -> ItemOutcome {
        let name = source.lastPathComponent
        guard let loc = RemoteLocation(url: destDir) else { return .failed(.destinationUnavailable(destDir.lastPathComponent)) }
        guard RemotePath.isValidName(name) else { return .failed(.invalidName("„\(name)” nie jest dozwoloną nazwą na serwerze.")) }
        let rv = try? source.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        if rv?.isSymbolicLink == true { return .skipped("dowiązanie symboliczne — pominięto (nie jest wysyłane ani rozwijane)") }
        guard FileManager.default.fileExists(atPath: source.path) else { return .failed(.sourceMissing(name)) }
        let isDir = rv?.isDirectory == true

        do {
            let provider = try await providerFor(loc.connectionID)
            guard provider.capabilities.write else { throw NetworkError.unsupported("zapis") }
            var finalName = name
            var replacing = false
            if let existing = try await provider.stat(try loc.path.appending(name)) {
                let existingURL = try loc.appending(name).url
                switch await resolve(source: source, existing: existingURL, ctx: &ctx) {
                case .skip: return .skipped("konflikt nazw — pominięto")
                case .keepBoth: finalName = try await uniqueRemoteName(name, isDirectory: isDir, in: loc.path, provider: provider)
                case .replace:
                    if isDir || existing.isDirectory {
                        return .failed(.other(name: name, reason: "zastąpienie folderu na serwerze nie jest obsługiwane (byłoby to nieodwracalne usunięcie całego drzewa) — wybierz „zachowaj obie” albo pomiń."))
                    }
                    replacing = true
                }
            }
            let target = try loc.path.appending(finalName)
            if isDir {
                try await uploadDirectory(source, to: target, provider: provider, depth: 0, ctx: ctx)
            } else {
                try await uploadFile(source, to: target, replacing: replacing, provider: provider, ctx: ctx)
            }
            return .completed(try loc.appending(finalName).url)
        } catch {
            return Self.outcomeError(error, name: name)
        }
    }

    private func uploadDirectory(_ local: URL, to remote: RemotePath, provider: any FileProvider, depth: Int, ctx: Context) async throws {
        guard depth < Self.maxDepth else { throw NetworkError.other("zbyt głęboka struktura folderów (limit \(Self.maxDepth)).") }
        try Task.checkCancellation()
        guard provider.capabilities.makeDirectory else { throw NetworkError.unsupported("tworzenie folderów") }
        try await provider.makeDirectory(remote)
        let children = try FileManager.default.contentsOfDirectory(at: local, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        var failures: [String] = []
        for child in children {
            try Task.checkCancellation()
            let cname = child.lastPathComponent
            guard RemotePath.isValidName(cname) else { failures.append(cname); continue }
            let rv = try? child.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            if rv?.isSymbolicLink == true { continue }
            do {
                let target = try remote.appending(cname)
                if rv?.isDirectory == true {
                    try await uploadDirectory(child, to: target, provider: provider, depth: depth + 1, ctx: ctx)
                } else {
                    try await uploadFile(child, to: target, replacing: false, provider: provider, ctx: ctx)
                }
            } catch {
                if error is CancellationError || (error as? NetworkError) == .cancelled { throw error }
                failures.append("\(cname): \(Redactor.redact((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))")
                if let n = error as? NetworkError, n == .connectionLost || n == .timeout { throw n }
            }
        }
        if !failures.isEmpty {
            throw NetworkError.other("nie wysłano \(failures.count) elementów w „\(remote.lastComponent ?? "/")”: " + failures.prefix(3).joined(separator: "; "))
        }
    }

    private func uploadFile(_ local: URL, to remote: RemotePath, replacing: Bool, provider: any FileProvider, ctx: Context) async throws {
        let size = (try? FileManager.default.attributesOfItem(atPath: local.path)[.size] as? NSNumber)?.int64Value ?? 0
        let meter = ctx.meter
        let useTemp = provider.capabilities.rename
        let dir = remote.parent
        let tmp = try dir.appending("\(Self.tempPrefix)\(UUID().uuidString)")
        let writeTarget = useTemp ? tmp : remote
        do {
            try await provider.upload(from: local, to: writeTarget, overwrite: useTemp ? false : replacing) { meter.fileProgress($0) }
            if let remoteSize = try await provider.stat(writeTarget)?.size, remoteSize != size {
                throw NetworkError.invalidResponse("rozmiar na serwerze (\(remoteSize) B) różni się od lokalnego (\(size) B) — transfer uznany za nieudany.")
            }
            if useTemp {
                if replacing {
                    guard provider.capabilities.delete else { throw NetworkError.unsupported("usuwanie (potrzebne do zastąpienia)") }
                    try await provider.delete(remote, isDirectory: false)
                }
                do { try await provider.rename(tmp, to: remote) } catch {
                    throw NetworkError.other("plik został wysłany, ale nie udało się nadać mu docelowej nazwy; nowa wersja została na serwerze jako „\(tmp.lastComponent ?? "")”.")
                }
            }
            meter.fileFinished(size: size)
        } catch {
            if useTemp {
                // Sprzątamy wyłącznie własny plik tymczasowy (najlepsza próba; przy zerwanym połączeniu może zostać).
                // Serwer mógł dokończyć zapis już po anulowaniu/zerwaniu (np. HTTP) — jeśli plik nadal jest, ponawiamy usunięcie krótko.
                await Task.detached {
                    for delay: UInt64 in [0, 300_000_000, 900_000_000] {
                        if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
                        try? await provider.delete(tmp, isDirectory: false)
                        if (try? await provider.stat(tmp)) == nil { break }
                    }
                }.value
            }
            throw error
        }
    }

    // MARK: - Download

    private func downloadItem(_ source: URL, into destDir: URL, ctx: inout Context) async -> ItemOutcome {
        guard let loc = RemoteLocation(url: source), let name = loc.path.lastComponent else {
            return .failed(.sourceMissing(source.lastPathComponent))
        }
        guard let finalTargetBase = LocalMapping.url(for: name, in: destDir) else {
            return .failed(.invalidName("„\(name)” (nazwa z serwera) wychodzi poza folder docelowy — zablokowano."))
        }
        var isDirDest: ObjCBool = false
        guard FileManager.default.fileExists(atPath: destDir.path, isDirectory: &isDirDest), isDirDest.boolValue else {
            return .failed(.destinationUnavailable(destDir.lastPathComponent))
        }
        do {
            let provider = try await providerFor(loc.connectionID)
            guard provider.capabilities.read else { throw NetworkError.unsupported("odczyt") }
            guard let entry = try await provider.stat(loc.path) else { throw NetworkError.notFound(loc.path.string) }

            var isDirectory = entry.isDirectory
            if entry.kind == .symlink {
                guard entry.symlinkTargetIsDirectory == false else { return .skipped("dowiązanie do folderu — pominięto (nie podążamy za zdalnymi dowiązaniami)") }
                isDirectory = false
            } else if entry.kind == .other {
                return .skipped("specjalny plik na serwerze — pominięto")
            }

            var finalTarget = finalTargetBase
            var replacing = false
            if FileOperationEngine.exists(finalTarget) {
                switch await resolve(source: source, existing: finalTarget, ctx: &ctx) {
                case .skip: return .skipped("konflikt nazw — pominięto")
                case .keepBoth: finalTarget = FileOperationEngine.uniqueURL(for: finalTarget, like: isDirectory ? destDir : finalTarget)
                case .replace: replacing = true
                }
            }

            let tmp = destDir.appendingPathComponent("\(Self.tempPrefix)\(UUID().uuidString)")
            journal?.register(.init(tmp: tmp.path, kind: .copy, original: nil))
            defer { journal?.unregister(tmpPath: tmp.path) }
            do {
                if isDirectory {
                    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: false)
                    try await downloadDirectory(loc.path, to: tmp, provider: provider, depth: 0, ctx: ctx)
                } else {
                    try await downloadFile(loc.path, size: entry.size, to: tmp, provider: provider, ctx: ctx)
                }
                if replacing {
                    do { try trasher.trash(finalTarget) } catch {
                        throw OperationError.trashFailed(name: finalTarget.lastPathComponent, reason: (error as NSError).localizedDescription)
                    }
                }
                try FileManager.default.moveItem(at: tmp, to: finalTarget)
            } catch {
                try? FileManager.default.removeItem(at: tmp) // wyłącznie nasz plik/folder tymczasowy
                throw error
            }
            return .completed(finalTarget)
        } catch {
            return Self.outcomeError(error, name: name)
        }
    }

    private func downloadFile(_ remote: RemotePath, size: Int64?, to tmp: URL, provider: any FileProvider, ctx: Context) async throws {
        let meter = ctx.meter
        try await provider.download(remote, to: tmp) { meter.fileProgress($0) }
        let got = (try? FileManager.default.attributesOfItem(atPath: tmp.path)[.size] as? NSNumber)?.int64Value ?? -1
        if let size, got != size {
            throw NetworkError.invalidResponse("pobrano \(got) B zamiast \(size) B — plik jest niekompletny i został odrzucony.")
        }
        meter.fileFinished(size: got)
    }

    private func downloadDirectory(_ remote: RemotePath, to localDir: URL, provider: any FileProvider, depth: Int, ctx: Context) async throws {
        guard depth < Self.maxDepth else { throw NetworkError.other("zbyt głęboka struktura folderów na serwerze (limit \(Self.maxDepth)).") }
        try Task.checkCancellation()
        let entries = try await provider.list(remote)
        var problems: [String] = []
        for e in entries.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
            try Task.checkCancellation()
            guard let target = LocalMapping.url(for: e.name, in: localDir) else { problems.append("„\(e.name)” (niedozwolona nazwa)"); continue }
            switch e.kind {
            case .symlink, .other: continue // nie rozwijamy dowiązań ani plików specjalnych
            case .directory:
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
                try await downloadDirectory(try remote.appending(e.name), to: target, provider: provider, depth: depth + 1, ctx: ctx)
            case .file:
                do {
                    try await downloadFile(try remote.appending(e.name), size: e.size, to: target, provider: provider, ctx: ctx)
                } catch {
                    try? FileManager.default.removeItem(at: target)
                    if error is CancellationError || (error as? NetworkError) == .cancelled { throw error }
                    if let n = error as? NetworkError, n == .connectionLost || n == .timeout { throw n }
                    problems.append("\(e.name): \(Redactor.redact((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))")
                }
            }
        }
        if !problems.isEmpty {
            throw NetworkError.other("nie pobrano \(problems.count) elementów z „\(remote.lastComponent ?? "/")”: " + problems.prefix(3).joined(separator: "; "))
        }
    }

    // MARK: - Usuwanie na serwerze

    private func deleteItem(_ source: URL) async -> ItemOutcome {
        guard let loc = RemoteLocation(url: source), let name = loc.path.lastComponent else {
            return .failed(.other(name: source.lastPathComponent, reason: "nie można usunąć korzenia serwera."))
        }
        do {
            let provider = try await providerFor(loc.connectionID)
            guard provider.capabilities.delete else { throw NetworkError.unsupported("usuwanie") }
            guard let entry = try await provider.stat(loc.path) else { return .skipped("już nie istnieje na serwerze") }
            // Dowiązanie usuwamy jako dowiązanie (nie wchodzimy do celu).
            if entry.isDirectory && entry.kind != .symlink {
                try await deleteTree(loc.path, provider: provider, depth: 0)
            } else {
                try await provider.delete(loc.path, isDirectory: false)
            }
            return .completed(nil)
        } catch {
            return Self.outcomeError(error, name: name)
        }
    }

    private func deleteTree(_ path: RemotePath, provider: any FileProvider, depth: Int) async throws {
        guard depth < Self.maxDepth else { throw NetworkError.other("zbyt głęboka struktura folderów (limit \(Self.maxDepth)).") }
        for e in try await provider.list(path) {
            try Task.checkCancellation()
            let child = try path.appending(e.name)
            if e.kind == .directory { try await deleteTree(child, provider: provider, depth: depth + 1) }
            else { try await provider.delete(child, isDirectory: false) } // pliki i dowiązania
        }
        try Task.checkCancellation()
        try await provider.delete(path, isDirectory: true)
    }
}
