import Foundation
import CryptoKit
import NIOCore
import NIOSSH
import Citadel
import OpenCommanderCore

/// Klient SFTP oparty na bibliotece Citadel (SSH i SFTP nie są implementowane we własnym zakresie).
///
/// Ograniczenia, o których trzeba pamiętać:
/// - brak wznawiania transferów; kawałki 32 KiB są wysyłane/odbierane sekwencyjnie (przepustowość zależy od opóźnienia sieci);
/// - biblioteka nie udostępnia `lstat`, więc rodzaj elementu (w tym dowiązanie) ustalamy z listingu katalogu nadrzędnego
///   (z krótkim cache’em), a nie z `stat` — dzięki temu dowiązania nigdy nie są mylone z katalogami;
/// - klucze prywatne: Ed25519 i RSA w formacie OpenSSH (`BEGIN OPENSSH PRIVATE KEY`), także zaszyfrowane passphrase.
public final class SFTPProvider: FileProvider, @unchecked Sendable {
    public static let chunkSize = 32 * 1024

    private let profile: ConnectionProfile
    private let context: ProviderContext
    private let gate = AsyncMutex()
    private let lock = NSLock()
    private var ssh: SSHClient?
    private var sftp: SFTPClient?
    private var cache: [String: (at: Date, entries: [String: RemoteEntry])] = [:]
    private let cacheTTL: TimeInterval = 2
    /// Limit czasu na odpowiedź pojedynczego żądania (Citadel nie ma własnego timeoutu dla większości żądań —
    /// bez tego martwe łącze przy żywym TCP zawiesiłoby operację na zawsze).
    let operationTimeout: TimeInterval

    public var capabilities: ProviderCapabilities {
        var c = ProviderCapabilities()
        c.reliableMetadata = true
        return c
    }

    public init(profile: ConnectionProfile, context: ProviderContext, operationTimeout: TimeInterval = 30) {
        self.profile = profile
        self.context = context
        self.operationTimeout = operationTimeout
    }

    /// Wykonuje żądanie pod mutexem sesji z limitem czasu. Po przekroczeniu limitu sesja jest zamykana
    /// (stan żądania w toku jest nieznany), więc kolejne użycie połączy ponownie — nic nie jest ponawiane automatycznie.
    private func call<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let gate = self.gate, timeout = operationTimeout
        let once = OnceFlag()
        // Anulowanie zadania wołającego nie przerywa żądania w locie (stan kanału byłby nieznany) — kończy się je między kawałkami
        // transferu (`Task.checkCancellation`) albo limitem czasu.
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            // Czasomierz jest anulowany, gdy żądanie się zakończy — inaczej każdy kawałek transferu zostawiałby
            // uśpione zadanie na `timeout` sekund (przy 1 GB to dziesiątki tysięcy zadań naraz).
            let timer = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) } catch { return }
                if once.fire() {
                    once.cancelWork()
                    cont.resume(throwing: NetworkError.timeout)
                    await self?.disconnect()   // zamknięcie kanału kończy też zawieszone żądanie i zwalnia mutex
                }
            }
            let work = Task {
                do { let v = try await gate.run(body); if once.fire() { cont.resume(returning: v) } }
                catch { if once.fire() { cont.resume(throwing: error) } }
                timer.cancel()
            }
            once.attach(work)
        }
    }

    // MARK: Połączenie

    public func connect() async throws {
        let keyHolder = HostKeyErrorBox()
        let auth = try authenticationMethod()
        var settings = SSHClientSettings(
            host: profile.host, port: profile.port,
            authenticationMethod: { auth },
            hostKeyValidator: .custom(HostKeyDelegate(host: profile.host, port: profile.port, verifier: context.hostKeyVerifier, box: keyHolder))
        )
        settings.connectTimeout = .seconds(Int64(profile.connectTimeoutSeconds))
        do {
            let client = try await SSHClient.connect(to: settings)
            let sftp: SFTPClient
            do { sftp = try await client.openSFTP() } catch {
                try? await client.close()   // połączenie SSH już istnieje — nie zostawiamy go otwartego
                throw error
            }
            lock.withLock { self.ssh = client; self.sftp = sftp }
        } catch {
            // Błąd zaufania do klucza hosta ma pierwszeństwo przed ogólnym błędem połączenia.
            if let e = keyHolder.error { throw e }
            throw Self.map(error, secrets: context.credentials.allSecrets, host: profile.host)
        }
    }

    public func disconnect() async {
        let (s, c) = lock.withLock { () -> (SFTPClient?, SSHClient?) in
            defer { sftp = nil; ssh = nil; cache = [:] }
            return (sftp, ssh)
        }
        try? await s?.close()
        try? await c?.close()
    }

    private func client() throws -> SFTPClient {
        guard let s = lock.withLock({ sftp }), s.isActive else { throw NetworkError.connectionLost }
        return s
    }

    private func authenticationMethod() throws -> SSHAuthenticationMethod {
        let user = profile.username
        switch profile.auth {
        case .anonymous:
            throw NetworkError.invalidProfile("SFTP nie obsługuje logowania anonimowego.")
        case .password:
            guard let pw = context.credentials.password else { throw NetworkError.authenticationFailed }
            return .passwordBased(username: user, password: pw)
        case .privateKey:
            guard let path = profile.keyFilePath else { throw NetworkError.invalidProfile("brak ścieżki klucza.") }
            let text: String
            do { text = try String(contentsOfFile: (path as NSString).expandingTildeInPath, encoding: .utf8) }
            catch { throw NetworkError.other("Nie można odczytać pliku klucza „\((path as NSString).lastPathComponent)” (sprawdź ścieżkę i uprawnienia).") }
            let passphrase = context.credentials.passphrase.map { Data($0.utf8) }
            do {
                switch try SSHKeyDetection.detectPrivateKeyType(from: text) {
                case .ed25519:
                    return .ed25519(username: user, privateKey: try Curve25519.Signing.PrivateKey(sshEd25519: text, decryptionKey: passphrase))
                case .rsa:
                    return .rsa(username: user, privateKey: try Insecure.RSA.PrivateKey(sshRsa: text, decryptionKey: passphrase))
                default:
                    throw NetworkError.unsupported("ten typ klucza prywatnego (obsługiwane: Ed25519 i RSA w formacie OpenSSH)")
                }
            } catch let e as SSHKeyDetectionError {
                switch e {
                case .passphraseRequired, .encryptedPrivateKey:
                    throw NetworkError.invalidProfile("klucz prywatny jest zaszyfrowany — wpisz jego hasło (passphrase) w edycji połączenia.")
                case .incorrectPassphrase:
                    throw NetworkError.invalidProfile("nieprawidłowe hasło (passphrase) do klucza prywatnego.")
                default: throw NetworkError.invalidProfile("nie można odczytać klucza prywatnego (\(e.localizedDescription)).")
                }
            }
        }
    }

    // MARK: Operacje

    public func initialPath() async throws -> RemotePath {
        let configured = profile.initialPath.trimmingCharacters(in: .whitespaces)
        let start = (configured.isEmpty || configured == "~") ? "." : configured
        let c = try client()
        do { return RemotePath(parsing: try await call { try await c.getRealPath(atPath: start) }) }
        catch { throw mapped(error) }
    }

    public func list(_ path: RemotePath) async throws -> [RemoteEntry] {
        let c = try client()
        do {
            let names = try await call { try await c.listDirectory(atPath: path.string) }
            var out: [RemoteEntry] = []
            for comp in names.flatMap(\.components) where comp.filename != "." && comp.filename != ".." {
                try Task.checkCancellation()
                guard RemotePath.isValidName(comp.filename) else { continue } // nazwy niezaufane — odrzucamy niebezpieczne
                var entry = Self.entry(from: comp)
                if entry.kind == .symlink {
                    // stat podąża za dowiązaniem — ustalamy tylko, czy cel to katalog (wejście do niego jest jawne i jednopoziomowe).
                    let target = try? await call { try await c.getAttributes(at: (try path.appending(comp.filename)).string) }
                    entry.symlinkTargetIsDirectory = target.flatMap { $0.permissions }.map { $0 & 0o170000 == 0o040000 }
                }
                out.append(entry)
            }
            lock.withLock { cache[path.string] = (Date(), Dictionary(out.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })) }
            return out
        } catch { throw mapped(error, path: path.string) }
    }

    public func stat(_ path: RemotePath) async throws -> RemoteEntry? {
        if path.isRoot { return RemoteEntry(name: "/", kind: .directory) }
        let parent = path.parent
        let name = path.lastComponent!
        if let hit = lock.withLock({ cache[parent.string] }), Date().timeIntervalSince(hit.at) < cacheTTL {
            return hit.entries[name]
        }
        do { return try await list(parent).first { $0.name == name } }
        catch let e as NetworkError { if case .notFound = e { return nil }; throw e }
    }

    public func download(_ path: RemotePath, to localFile: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let c = try client()
        FileManager.default.createFile(atPath: localFile.path, contents: nil)
        let out = try FileHandle(forWritingTo: localFile)
        defer { try? out.close() }
        do {
            let file = try await call { try await c.openFile(filePath: path.string, flags: .read) }
            var offset: UInt64 = 0
            do {
                while true {
                    try Task.checkCancellation()
                    let at = offset
                    let buf = try await call { try await file.read(from: at, length: UInt32(Self.chunkSize)) }
                    guard buf.readableBytes > 0 else { break }
                    try out.write(contentsOf: Data(buffer: buf))
                    offset += UInt64(buf.readableBytes)
                    progress(Int64(offset))
                }
            } catch {
                try? await call { try await file.close() }
                throw error
            }
            try await call { try await file.close() }
        } catch {
            if let io = error as? CocoaError, io.code == .fileWriteOutOfSpace { throw NetworkError.noSpace }
            throw mapped(error, path: path.string)
        }
    }

    public func upload(from localFile: URL, to path: RemotePath, overwrite: Bool, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let c = try client()
        let input = try FileHandle(forReadingFrom: localFile)
        defer { try? input.close() }
        let flags: SFTPOpenFileFlags = overwrite ? [.write, .create, .truncate]
                                                 : [.write, .create, .forceCreate]   // forceCreate = O_EXCL: serwer odmówi, jeśli plik istnieje
        do {
            let file = try await call { try await c.openFile(filePath: path.string, flags: flags) }
            var offset: UInt64 = 0
            do {
                while true {
                    try Task.checkCancellation()
                    guard let chunk = try input.read(upToCount: Self.chunkSize), !chunk.isEmpty else { break }
                    let buf = ByteBuffer(data: chunk)
                    let at = offset
                    try await call { try await file.write(buf, at: at) }
                    offset += UInt64(chunk.count)
                    progress(Int64(offset))
                }
            } catch {
                try? await call { try await file.close() }
                throw error
            }
            try await call { try await file.close() }
            invalidate(path.parent)
        } catch {
            invalidate(path.parent)
            throw mapped(error, path: path.string)
        }
    }

    public func makeDirectory(_ path: RemotePath) async throws {
        let c = try client()
        do { try await call { try await c.createDirectory(atPath: path.string) }; invalidate(path.parent) }
        catch { throw mapped(error, path: path.string, failureMeansConflict: true) }
    }

    public func rename(_ from: RemotePath, to: RemotePath) async throws {
        let c = try client()
        do { try await call { try await c.rename(at: from.string, to: to.string) }; invalidate(from.parent); invalidate(to.parent) }
        catch { throw mapped(error, path: from.string, failureMeansConflict: true) }
    }

    public func delete(_ path: RemotePath, isDirectory: Bool) async throws {
        let c = try client()
        do {
            if isDirectory { try await call { try await c.rmdir(at: path.string) } }
            else { try await call { try await c.remove(at: path.string) } }
            invalidate(path.parent)
        } catch { throw mapped(error, path: path.string) }
    }

    // MARK: Pomocnicze

    private func invalidate(_ dir: RemotePath) { lock.withLock { cache[dir.string] = nil } }

    private func mapped(_ error: Error, path: String? = nil, failureMeansConflict: Bool = false) -> NetworkError {
        Self.map(error, secrets: context.credentials.allSecrets, host: profile.host, path: path, failureMeansConflict: failureMeansConflict)
    }

    static func entry(from comp: SFTPPathComponent) -> RemoteEntry {
        let perm = comp.attributes.permissions
        let kind: RemoteEntryKind
        switch perm.map({ $0 & 0o170000 }) {
        case 0o040000: kind = .directory
        case 0o100000: kind = .file
        case 0o120000: kind = .symlink
        case .some: kind = .other
        case nil: kind = comp.longname.hasPrefix("d") ? .directory : (comp.longname.hasPrefix("l") ? .symlink : .file)
        }
        return RemoteEntry(name: comp.filename, kind: kind, size: kind == .file ? comp.attributes.size.map(Int64.init) : nil,
                           modified: comp.attributes.accessModificationTime?.modificationTime,
                           permissions: perm.map(Self.permissionString))
    }

    static func permissionString(_ mode: UInt32) -> String {
        let bits = "rwxrwxrwx"
        return String(bits.enumerated().map { (i, ch) in mode & (1 << UInt32(8 - i)) != 0 ? ch : "-" })
    }

    static func map(_ error: Error, secrets: [String], host: String, path: String? = nil, failureMeansConflict: Bool = false) -> NetworkError {
        if error is CancellationError { return .cancelled }
        if let n = error as? NetworkError { return n }
        let p = path ?? "?"
        if let s = error as? SFTPError {
            switch s {
            case .errorStatus(let status):
                switch status.errorCode {
                case .noSuchFile: return .notFound(p)
                case .permissionDenied: return .permissionDenied(p)
                case .unsupportedOperation: return .unsupported("operacja SFTP")
                case .connectionLost, .noConnection: return .connectionLost
                case .failure: return failureMeansConflict ? .conflict(p) : .other(Redactor.redact("serwer zgłosił błąd: \(status.message)", secrets: secrets))
                default: return .other(Redactor.redact("serwer zgłosił błąd: \(status.message)", secrets: secrets))
                }
            case .connectionClosed: return .connectionLost
            case .missingResponse: return .timeout
            default: return .invalidResponse("\(s)")
            }
        }
        if let k = error as? SSHKeyDetectionError { return .invalidProfile(k.localizedDescription) }
        let text = "\(error)"
        let lower = text.lowercased()
        if lower.contains("authentication") && (lower.contains("fail") || lower.contains("denied") || lower.contains("option")) { return .authenticationFailed }
        if lower.contains("dns") || lower.contains("nodename") || lower.contains("getaddrinfo") || lower.contains("unknown host") { return .dnsFailure(host: host) }
        if lower.contains("timeout") || lower.contains("timed out") { return .timeout }
        if lower.contains("connection refused") || lower.contains("errno: 61") { return .connectionFailed("połączenie odrzucone (serwer nie nasłuchuje na tym porcie).") }
        if lower.contains("connectionclosed") || lower.contains("alreadyclosed") || lower.contains("ioonclosedchannel") || lower.contains("eof") { return .connectionLost }
        return .connectionFailed(Redactor.redact(text, secrets: secrets))
    }
}

/// Jednorazowa flaga (wyścig odpowiedź/timeout: wygrywa pierwszy).
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock(); private var done = false
    private var work: Task<Void, Never>?
    func fire() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
    /// Po przekroczeniu limitu czasu przerywamy zadanie robocze (jeśli już się zakończyło, nic się nie dzieje).
    func attach(_ task: Task<Void, Never>) { lock.withLock { work = task } }
    func cancelWork() { lock.withLock { work }?.cancel() }
}

/// Przechowuje błąd zaufania do klucza hosta, żeby wypłynął zamiast ogólnego błędu połączenia.
final class HostKeyErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: NetworkError?
    var error: NetworkError? { get { lock.withLock { stored } } set { lock.withLock { stored = newValue } } }
}

/// Łączy Citadel/NIOSSH z `HostKeyVerifier` (TOFU z odciskiem i blokadą zmiany klucza).
final class HostKeyDelegate: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    let host: String, port: Int, verifier: HostKeyVerifier, box: HostKeyErrorBox
    init(host: String, port: Int, verifier: HostKeyVerifier, box: HostKeyErrorBox) {
        self.host = host; self.port = port; self.verifier = verifier; self.box = box
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let info = Self.info(for: hostKey, host: host, port: port)
        Task {
            do { try await verifier.verify(info); validationCompletePromise.succeed(()) }
            catch { box.error = error as? NetworkError ?? .hostKeyRejected; validationCompletePromise.fail(error) }
        }
    }

    /// Odcisk w formacie OpenSSH: SHA256 z binarnego klucza publicznego, base64 bez dopełnienia.
    static func info(for key: NIOSSHPublicKey, host: String, port: Int) -> HostKeyInfo {
        let line = String(openSSHPublicKey: key)                  // „ssh-ed25519 AAAA…”
        let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
        let type = parts.first ?? "unknown"
        let blob = parts.count > 1 ? Data(base64Encoded: parts[1]) ?? Data() : Data()
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return HostKeyInfo(host: host, port: port, keyType: type, fingerprint: "SHA256:" + digest)
    }
}
