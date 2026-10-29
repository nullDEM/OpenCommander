import Foundation
import CCurl
import OpenCommanderCore

/// Klient FTP / FTPS na systemowym libcurl (FTP ani TLS nie są implementowane we własnym zakresie).
///
/// Zasady bezpieczeństwa:
/// - FTPS: `CURLUSESSL_ALL` (TLS dla połączenia sterującego i danych) — jeśli serwer nie wspiera TLS, połączenie kończy się błędem,
///   **nigdy** nie spada po cichu do zwykłego FTP. Certyfikat i nazwa hosta są weryfikowane (bez „akceptuj wszystko”), TLS ≥ 1.2.
/// - Zwykłe FTP wymaga jawnej zgody w profilu (`allowInsecure`); dane i hasło idą wtedy jawnym tekstem.
/// - Tryb pasywny (EPSV/PASV), adres IP z odpowiedzi PASV jest ignorowany (używamy adresu połączenia sterującego).
/// - Transfery binarne. Listing: preferowane MLSD; gdy serwer go nie ma — LIST (heurystyka, tylko formaty unixowy i DOS).
/// - Hasło nie trafia do adresu URL ani do logów (przechwytujemy tylko odpowiedzi serwera).
///
/// Ograniczenia: brak wznawiania; `stat` jest wyprowadzany z listingu katalogu nadrzędnego (FTP nie ma jednolitego `stat`);
/// czas modyfikacji z LIST bywa przybliżony; jedno połączenie, operacje szeregowo.
public final class FTPProvider: FileProvider, @unchecked Sendable {
    private let profile: ConnectionProfile
    private let context: ProviderContext
    private let trustedCA: URL?
    private let queue = DispatchQueue(label: "org.opencommander.ftp", qos: .userInitiated)
    private let lock = NSLock()
    private var handle: CurlHandle?                 // dotykany tylko na `queue`
    private var homePath: RemotePath = .root        // tylko na `queue`
    private var mlsd: Bool?                         // nil = jeszcze nie sprawdzono
    private var cache: [String: (at: Date, entries: [String: RemoteEntry])] = [:]   // tylko na `queue`
    private var activeToken: CancelToken?
    private let cacheTTL: TimeInterval = 2
    private var connected = false

    public var capabilities: ProviderCapabilities {
        var c = ProviderCapabilities()
        c.reliableMetadata = lock.withLock { mlsd } != false   // po przejściu na LIST metadane są tylko heurystyczne
        return c
    }

    /// `trustedCA` (tylko testy/zaawansowane): plik z certyfikatem CA, który *zastępuje* zaufane korzenie dla tego połączenia
    /// (zawęża zaufanie, nie wyłącza weryfikacji).
    init(profile: ConnectionProfile, context: ProviderContext, trustedCA: URL?) throws {
        guard profile.proto == .ftp || profile.proto == .ftps else { throw NetworkError.invalidProfile("to nie jest profil FTP.") }
        if profile.proto == .ftp && !profile.allowInsecure { throw NetworkError.insecureConnectionRefused("zwykłe FTP wymaga jawnej zgody w profilu.") }
        self.profile = profile; self.context = context; self.trustedCA = trustedCA
    }

    public convenience init(profile: ConnectionProfile, context: ProviderContext) throws {
        try self.init(profile: profile, context: context, trustedCA: nil)
    }

    // MARK: Adresy

    private var scheme: String { (profile.proto == .ftps && profile.ftpsMode == .implicit) ? "ftps" : "ftp" }
    private var hostPort: String { "\(profile.host.contains(":") ? "[\(profile.host)]" : profile.host):\(profile.port)" }

    /// Adres bezwzględny (`//` po hoście = ścieżka od korzenia serwera, nie od katalogu domowego).
    func url(for path: RemotePath, directory: Bool) -> String {
        var s = "\(scheme)://\(hostPort)//" + path.components.map(RemoteLocation.encode(component:)).joined(separator: "/")
        if directory && !s.hasSuffix("/") { s += "/" }
        return s
    }

    private var homeURL: String { "\(scheme)://\(hostPort)/" }

    /// Ścieżka trafiająca do polecenia FTP (QUOTE) jako surowy tekst — bez CR/LF/NUL (ochrona przed wstrzyknięciem poleceń).
    private func commandPath(_ p: RemotePath) throws -> String {
        let s = p.string
        guard !s.unicodeScalars.contains(where: { $0.value == 0 || $0.value == 10 || $0.value == 13 }) else { throw NetworkError.invalidPath(s) }
        return s
    }

    // MARK: Wykonywanie na kolejce

    private func run<T: Sendable>(_ work: @escaping @Sendable (CurlHandle, CancelToken) throws -> T) async throws -> T {
        let token = CancelToken()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
                queue.async { [self] in
                    if token.isCancelled { cont.resume(throwing: NetworkError.cancelled); return }
                    lock.withLock { activeToken = token }
                    defer { lock.withLock { activeToken = nil } }
                    do {
                        if handle == nil { handle = try CurlHandle() }
                        cont.resume(returning: try work(handle!, token))
                    } catch { cont.resume(throwing: error) }
                }
            }
        } onCancel: { token.cancel() }
    }

    private func baseConfig(_ c: CurlConfig) {
        c.long(CURLOPT_CONNECTTIMEOUT, profile.connectTimeoutSeconds)
        c.long(CURLOPT_SERVER_RESPONSE_TIMEOUT, max(profile.connectTimeoutSeconds * 2, 5))
        c.long(CURLOPT_LOW_SPEED_LIMIT, 1)
        c.long(CURLOPT_LOW_SPEED_TIME, max(profile.connectTimeoutSeconds, 5))   // transfer bez postępu dłużej niż tyle = zerwany
        c.long(CURLOPT_FTP_SKIP_PASV_IP, 1)
        c.long(CURLOPT_FTP_USE_EPSV, 1)
        c.long(CURLOPT_FTP_FILEMETHOD, Int(CURLFTPMETHOD_SINGLECWD.rawValue))
        c.long(CURLOPT_FTP_CREATE_MISSING_DIRS, 0)
        c.long(CURLOPT_TRANSFERTEXT, 0)        // binarnie
        if profile.auth == .anonymous {
            c.str(CURLOPT_USERNAME, "anonymous"); c.str(CURLOPT_PASSWORD, "anonymous@")
        } else {
            c.str(CURLOPT_USERNAME, profile.username)
            c.str(CURLOPT_PASSWORD, context.credentials.password ?? "")
        }
        if profile.proto == .ftps {
            c.long(CURLOPT_USE_SSL, Int(CURLUSESSL_ALL.rawValue))        // wymagany TLS — bez cichego obniżania
            c.long(CURLOPT_FTPSSLAUTH, Int(CURLFTPAUTH_TLS.rawValue))     // jawny FTPS: AUTH TLS (nie przestarzałe AUTH SSL)
            // TLS dokładnie 1.2: serwery FTP (np. ProFTPD) wymagają wznowienia sesji TLS na kanale danych, a libcurl robi to
            // niezawodnie tylko w TLS 1.2 — przy 1.3 serwer odpowiada 425. TLS 1.2 nadal jest bezpieczny.
            c.long(CURLOPT_SSLVERSION, Int(CURL_SSLVERSION_TLSv1_2) | Int(CURL_SSLVERSION_MAX_TLSv1_2))
            c.long(CURLOPT_SSL_VERIFYPEER, 1)
            c.long(CURLOPT_SSL_VERIFYHOST, 2)
            if let ca = trustedCA { c.str(CURLOPT_CAINFO, ca.path) }
        }
    }

    // MARK: Połączenie

    public func connect() async throws {
        let homeURL = self.homeURL
        do {
            let home: RemotePath = try await run { [self] h, token in
                let op = CurlOperation(token: token)
                let rc = h.perform(op) { c in
                    baseConfig(c); c.str(CURLOPT_URL, homeURL); c.long(CURLOPT_NOBODY, 1)
                }
                try check(rc, op)
                // Po zalogowaniu libcurl pyta serwer o PWD (odpowiedź 257) — to katalog domowy.
                for line in op.serverLines where line.hasPrefix("257") {
                    if let p = Self.parsePWD(line) { return p }
                }
                return .root
            }
            queue.sync { homePath = home }
            lock.withLock { connected = true }
        } catch {
            await disconnect()
            throw mapped(error)
        }
    }

    public func disconnect() async {
        let token = lock.withLock { () -> CancelToken? in connected = false; return activeToken }
        token?.cancel()
        queue.async { [self] in handle?.close(); handle = nil; cache.removeAll() }
    }

    public func initialPath() async throws -> RemotePath {
        let configured = profile.initialPath.trimmingCharacters(in: .whitespaces)
        if !configured.isEmpty && configured != "~" { return RemotePath(parsing: configured) }
        return queue.sync { homePath }
    }

    /// `257 "/home/ola" is current directory` → `/home/ola` (cudzysłów podwojony oznacza cudzysłów w nazwie).
    static func parsePWD(_ line: String) -> RemotePath? {
        guard let first = line.firstIndex(of: "\"") else { return nil }
        var out = ""; var i = line.index(after: first)
        while i < line.endIndex {
            let ch = line[i]
            if ch == "\"" {
                let next = line.index(after: i)
                if next < line.endIndex, line[next] == "\"" { out.append("\""); i = line.index(after: next); continue }
                break
            }
            out.append(ch); i = line.index(after: i)
        }
        return out.isEmpty ? nil : RemotePath(parsing: out)
    }

    private func ensureConnected() throws { guard lock.withLock({ connected }) else { throw NetworkError.connectionLost } }

    // MARK: Listowanie

    public func list(_ path: RemotePath) async throws -> [RemoteEntry] {
        try ensureConnected()
        let dirURL = url(for: path, directory: true)
        do {
            let entries: [RemoteEntry] = try await run { [self] h, token in
                let r = try listDirectory(h, token, dirURL)
                return r
            }
            queue.async { [self] in cache[path.string] = (Date(), Dictionary(entries.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })) }
            return entries
        } catch { throw mapped(error, path: path.string) }
    }

    /// MLSD, a gdy serwer go nie zna (500/501/502/504) — LIST. Wołane na kolejce.
    private func listDirectory(_ h: CurlHandle, _ token: CancelToken, _ dirURL: String) throws -> [RemoteEntry] {
        func fetch(custom: String?) throws -> (String, CurlOperation, Int) {
            let op = CurlOperation(token: token)
            var data = Data()
            op.sink = { buf in
                data.append(contentsOf: buf)
                return data.count <= FTPListParser.maxBytes
            }
            let rc = h.perform(op) { [self] c in
                baseConfig(c); c.str(CURLOPT_URL, dirURL)
                if let custom { c.str(CURLOPT_CUSTOMREQUEST, custom) }
            }
            return (String(decoding: data, as: UTF8.self), op, rc)
        }
        if mlsd != false {
            let (text, op, rc) = try fetch(custom: "MLSD")
            if rc == 0 {
                lock.withLock { mlsd = true }
                return FTPListParser.parseMLSD(text).entries
            }
            if [500, 501, 502, 504].contains(op.lastReply?.code ?? 0) {
                lock.withLock { mlsd = false }      // serwer nie zna MLSD — przechodzimy na LIST (heurystyka)
            } else {
                try check(rc, op)
            }
        }
        let (text, op, rc) = try fetch(custom: nil)
        try check(rc, op)
        return FTPListParser.parseLIST(text).entries
    }

    public func stat(_ path: RemotePath) async throws -> RemoteEntry? { try await stat(path, fresh: false) }

    /// `fresh == true` pomija krótki cache listingu — używane przed zmianami (rename/usuwanie/MKD), żeby nie decydować na starych danych.
    func stat(_ path: RemotePath, fresh: Bool) async throws -> RemoteEntry? {
        try ensureConnected()
        guard let name = path.lastComponent else { return RemoteEntry(name: "", kind: .directory) }
        let parent = path.parent
        let cached = fresh ? nil : queue.sync { cache[parent.string].flatMap { Date().timeIntervalSince($0.at) < cacheTTL ? $0.entries : nil } }
        if let cached { return cached[name] }
        do { return try await list(parent).first { $0.name == name } }
        catch let e as NetworkError { if case .notFound = e { return nil }; throw e }
    }

    // MARK: Transfery

    public func download(_ path: RemotePath, to localFile: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        try ensureConnected()
        guard FileManager.default.createFile(atPath: localFile.path, contents: nil) else { throw NetworkError.permissionDenied(localFile.lastPathComponent) }
        let handleOut = try FileHandle(forWritingTo: localFile)
        defer { try? handleOut.close() }
        let fileURL = url(for: path, directory: false)
        do {
            try await run { [self] h, token in
                let op = CurlOperation(token: token)
                op.onProgress = progress
                var written: Int64 = 0
                op.sink = { buf in
                    do { try handleOut.write(contentsOf: Data(buf)); written += Int64(buf.count); return true } catch { return false }
                }
                let rc = h.perform(op) { c in baseConfig(c); c.str(CURLOPT_URL, fileURL) }
                try check(rc, op)
                // Niekompletne pobranie (zerwanie bez błędu) nie może wyglądać na udane.
                if let expected = h.infoOff(CURLINFO_CONTENT_LENGTH_DOWNLOAD_T), expected >= 0, expected != written { throw NetworkError.connectionLost }
            }
        } catch { throw mapped(error, path: path.string) }
    }

    public func upload(from localFile: URL, to path: RemotePath, overwrite: Bool, progress: @escaping @Sendable (Int64) -> Void) async throws {
        try ensureConnected()
        if !overwrite, try await stat(path, fresh: true) != nil { throw NetworkError.conflict(path.string) }
        let size = (try? FileManager.default.attributesOfItem(atPath: localFile.path)[.size] as? NSNumber)?.int64Value ?? 0
        let input = try FileHandle(forReadingFrom: localFile)
        defer { try? input.close() }
        let fileURL = url(for: path, directory: false)
        do {
            try await run { [self] h, token in
                let op = CurlOperation(token: token)
                op.onProgress = progress
                op.source = { buf in
                    guard let d = try? input.read(upToCount: buf.count), !d.isEmpty else { return 0 }
                    d.copyBytes(to: buf); return d.count
                }
                let rc = h.perform(op) { c in
                    baseConfig(c); c.str(CURLOPT_URL, fileURL)
                    c.long(CURLOPT_UPLOAD, 1); c.off(CURLOPT_INFILESIZE_LARGE, size)
                }
                try check(rc, op)
            }
            queue.async { [self] in cache.removeValue(forKey: path.parent.string) }
        } catch { throw mapped(error, path: path.string) }
    }

    // MARK: Zmiany (polecenia FTP przez QUOTE)

    private func quote(_ commands: [String], path: String) async throws {
        let home = homeURL
        do {
            try await run { [self] h, token in
                let op = CurlOperation(token: token)
                let rc = h.perform(op) { c in
                    baseConfig(c); c.str(CURLOPT_URL, home); c.long(CURLOPT_NOBODY, 1); c.slist(CURLOPT_QUOTE, commands)
                }
                try check(rc, op)
            }
        } catch { throw mapped(error, path: path) }
        queue.async { [self] in cache.removeAll() }
    }

    public func makeDirectory(_ path: RemotePath) async throws {
        try ensureConnected()
        if try await stat(path, fresh: true) != nil { throw NetworkError.conflict(path.string) }
        if path.parent != path, try await stat(path.parent, fresh: true) == nil, !path.parent.isRoot { throw NetworkError.notFound(path.parent.string) }
        try await quote(["MKD \(try commandPath(path))"], path: path.string)
    }

    public func rename(_ from: RemotePath, to: RemotePath) async throws {
        try ensureConnected()
        guard try await stat(from, fresh: true) != nil else { throw NetworkError.notFound(from.string) }
        if try await stat(to, fresh: true) != nil { throw NetworkError.conflict(to.string) }   // RNTO bywa nadpisujące — nie ryzykujemy
        try await quote(["RNFR \(try commandPath(from))", "RNTO \(try commandPath(to))"], path: from.string)
    }

    /// Usuwa plik albo PUSTY katalog.
    public func delete(_ path: RemotePath, isDirectory: Bool) async throws {
        try ensureConnected()
        guard try await stat(path, fresh: true) != nil else { throw NetworkError.notFound(path.string) }
        if isDirectory, !(try await list(path)).isEmpty { throw NetworkError.conflict("katalog „\(path.string)” nie jest pusty") }
        try await quote(["\(isDirectory ? "RMD" : "DELE") \(try commandPath(path))"], path: path.string)
    }

    // MARK: Błędy

    /// Zamienia kod libcurl (i ostatnią odpowiedź serwera) na `NetworkError`. `0` = sukces.
    private func check(_ rc: Int, _ op: CurlOperation) throws {
        if rc == 0 { return }
        let code = op.lastReply?.code ?? 0
        if code == 425 || code == 426 {
            throw NetworkError.connectionFailed("serwer nie pozwolił otworzyć kanału danych (\(code)). Zwykle winna jest zapora, tryb pasywny lub wymóg wznowienia sesji TLS po stronie serwera.")
        }
        switch rc {
        case 6: throw NetworkError.dnsFailure(host: profile.host)                                            // COULDNT_RESOLVE_HOST
        case 5: throw NetworkError.dnsFailure(host: profile.host)                                            // COULDNT_RESOLVE_PROXY
        case 7: throw NetworkError.connectionFailed("nie można nawiązać połączenia (serwer nie nasłuchuje lub adres jest niedostępny).")
        case 28: throw NetworkError.timeout                                                                  // OPERATION_TIMEDOUT
        case 10, 67: throw NetworkError.authenticationFailed                                                 // USER_PASSWORD_INCORRECT, LOGIN_DENIED
        case 9: throw Self.looksLikeMissing(op) ? NetworkError.notFound("zasób") : NetworkError.permissionDenied("zasób")   // REMOTE_ACCESS_DENIED (np. nieudane CWD)
        case 78: throw NetworkError.notFound("zasób")                                                        // REMOTE_FILE_NOT_FOUND
        case 3: throw NetworkError.invalidPath("adres")                                                      // URL_MALFORMAT
        case 42: throw NetworkError.cancelled                                                                // ABORTED_BY_CALLBACK
        case 64: throw NetworkError.insecureConnectionRefused("serwer nie obsługuje TLS — nie przełączam na połączenie bez szyfrowania.")  // USE_SSL_FAILED
        case 35, 51, 58, 59, 60, 66, 77, 83, 90, 91:                                                         // błędy TLS / certyfikatu
            throw NetworkError.tlsCertificateInvalid(Self.tlsReason(rc))
        case 18, 52, 55, 56: throw NetworkError.connectionLost                                               // PARTIAL_FILE, GOT_NOTHING, SEND_ERROR, RECV_ERROR
        case 23: throw NetworkError.noSpace                                                                  // WRITE_ERROR
        case 8, 13, 14, 15, 17: throw NetworkError.invalidResponse("nieoczekiwana odpowiedź serwera FTP (kod libcurl \(rc)).")
        case 25: throw code == 552 || code == 452 ? NetworkError.noSpace : (code == 550 || code == 553 ? NetworkError.permissionDenied("zasób") : NetworkError.other("serwer odrzucił zapis (\(code)).")) // UPLOAD_FAILED
        case 19: throw code == 550 ? (Self.looksLikeMissing(op) ? NetworkError.notFound("zasób") : NetworkError.permissionDenied("zasób")) : NetworkError.other("serwer nie wykonał polecenia (\(code)).")   // RETR_FILE
        case 21:                                                                                             // QUOTE_ERROR
            throw code == 550 ? NetworkError.permissionDenied("zasób") : (code == 553 ? NetworkError.conflict("zasób") : NetworkError.other("serwer odrzucił polecenie (\(code))."))
        default: throw NetworkError.connectionFailed(Redactor.redact("błąd libcurl \(rc): \(op.errorText)", secrets: context.credentials.allSecrets))
        }
    }

    /// Odpowiedź 550 oznacza zarówno „nie ma”, jak i „brak uprawnień” — rozróżniamy po treści odpowiedzi serwera.
    private static func looksLikeMissing(_ op: CurlOperation) -> Bool {
        let t = (op.lastReply?.line ?? op.errorText).lowercased()
        return ["no such", "not found", "does not exist", "doesn't exist", "not exist", "nie istnieje", "can't find", "cannot find"].contains { t.contains($0) }
    }

    private static func tlsReason(_ rc: Int) -> String {
        switch rc {
        case 60, 51: return "certyfikat serwera nie jest zaufany, wygasł albo nie pasuje do nazwy hosta."
        case 35: return "nie udało się ustanowić połączenia TLS."
        default: return "błąd weryfikacji TLS."
        }
    }

    private func mapped(_ error: Error, path: String? = nil) -> NetworkError {
        var n = ConnectionManager.networkError(error, secrets: context.credentials.allSecrets)
        // Uzupełnij nazwę zasobu w ogólnych błędach.
        switch n {
        case .notFound(let p) where p == "zasób": n = .notFound(path ?? p)
        case .permissionDenied(let p) where p == "zasób": n = .permissionDenied(path ?? p)
        case .conflict(let p) where p == "zasób": n = .conflict(path ?? p)
        default: break
        }
        return n
    }
}
