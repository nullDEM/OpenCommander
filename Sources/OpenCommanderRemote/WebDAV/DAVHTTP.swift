import Foundation
import OpenCommanderCore

struct DAVHTTPResult {
    var status: Int
    var headers: [String: String]   // klucze małymi literami
    var body: Data
}

/// Wykonuje żądania HTTP dla WebDAV z pełną kontrolą nad przekierowaniami i poświadczeniami:
/// - przekierowania obsługujemy ręcznie (URLSession nigdy nie podąża sam): tylko ten sam host i port, bez zejścia z HTTPS na HTTP;
/// - hasło trafia wyłącznie do odpowiedzi na wyzwanie (Basic/Digest) z tego samego hosta — nie ma ręcznego nagłówka Authorization,
///   więc nie może wyciec przy przekierowaniu;
/// - certyfikat TLS jest weryfikowany standardowo (delegat nie nadpisuje oceny zaufania).
final class DAVHTTPClient: @unchecked Sendable {
    let scheme: String
    let host: String
    let port: Int
    private let username: String?
    private let password: String?
    private let session: URLSession
    private let stateLock = NSLock()
    /// Po pierwszym wyzwaniu Basic dołączamy nagłówek od razu do kolejnych żądań tego klienta (wszystkie idą na ten sam host i port —
    /// przekierowania poza niego są blokowane). Dzięki temu duże PUT nie jest wysyłane dwa razy (raz bez, raz z hasłem).
    /// Digest wymaga wyzwania za każdym razem, więc tam treść może być wysłana ponownie.
    private var basicLearned = false
    static let maxRedirects = 5
    static let maxBufferedBody = 32 * 1024 * 1024

    init(baseURL: URL, username: String?, password: String?, timeout: TimeInterval) {
        self.scheme = baseURL.scheme?.lowercased() ?? "https"
        self.host = baseURL.host?.lowercased() ?? ""
        self.port = baseURL.port ?? (scheme == "https" ? 443 : 80)
        self.username = username
        self.password = password
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieStorage = nil
        cfg.urlCredentialStorage = nil
        cfg.httpShouldSetCookies = false
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = 7 * 24 * 3600
        cfg.waitsForConnectivity = false
        self.session = URLSession(configuration: cfg)
    }

    func invalidate() { session.invalidateAndCancel() }

    struct Body {
        var data: Data? = nil
        var file: URL? = nil
    }

    /// Wysyła żądanie, podążając (ręcznie i ostrożnie) za przekierowaniami. `sink` dostaje odebrane dane zamiast bufora.
    func send(_ method: String, _ url: URL, headers: [String: String] = [:], body: Body = Body(),
              sink: (@Sendable (Data) throws -> Void)? = nil,
              onSent: (@Sendable (Int64) -> Void)? = nil, onReceived: (@Sendable (Int64) -> Void)? = nil) async throws -> DAVHTTPResult {
        var target = url
        for _ in 0...Self.maxRedirects {
            let r = try await once(method, target, headers: headers, body: body, sink: sink, onSent: onSent, onReceived: onReceived)
            guard [301, 302, 303, 307, 308].contains(r.status), let loc = r.headers["location"] else { return r }
            guard let next = URL(string: loc, relativeTo: target)?.absoluteURL else { throw NetworkError.invalidResponse("nieprawidłowy adres przekierowania") }
            try validateRedirect(from: target, to: next)
            target = next
        }
        throw NetworkError.invalidResponse("zbyt wiele przekierowań")
    }

    /// Przekierowanie musi zostać na tym samym serwerze i nie może obniżać zabezpieczeń.
    func validateRedirect(from: URL, to: URL) throws {
        let toScheme = to.scheme?.lowercased() ?? ""
        if scheme == "https" && toScheme != "https" {
            throw NetworkError.insecureConnectionRefused("serwer przekierował z HTTPS na HTTP — połączenie przerwane.")
        }
        guard toScheme == "http" || toScheme == "https" else { throw NetworkError.invalidResponse("nieobsługiwany adres przekierowania") }
        let toPort = to.port ?? (toScheme == "https" ? 443 : 80)
        guard to.host?.lowercased() == host, toPort == port || (toScheme != scheme && toPort == (toScheme == "https" ? 443 : 80)) else {
            throw NetworkError.insecureConnectionRefused("serwer przekierował na inny adres — dane logowania nie są tam wysyłane.")
        }
    }

    private func once(_ method: String, _ url: URL, headers: [String: String], body: Body,
                      sink: (@Sendable (Data) throws -> Void)?, onSent: (@Sendable (Int64) -> Void)?, onReceived: (@Sendable (Int64) -> Void)?) async throws -> DAVHTTPResult {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpShouldHandleCookies = false
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if stateLock.withLock({ basicLearned }), let u = username, let p = password {
            req.setValue("Basic " + Data("\(u):\(p)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        }
        let delegate = TaskDelegate(host: host, username: username, password: password, sink: sink, onSent: onSent, onReceived: onReceived,
                                    onBasicChallenge: { [weak self] in self?.stateLock.withLock { self?.basicLearned = true } })
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<DAVHTTPResult, Error>) in
                let task: URLSessionTask
                if let file = body.file { task = session.uploadTask(with: req, fromFile: file) }
                else if let data = body.data { task = session.uploadTask(with: req, from: data) }
                else { task = session.dataTask(with: req) }
                delegate.start(task: task, continuation: cont)
                if Task.isCancelled { task.cancel() }
                task.resume()
            }
        } onCancel: { delegate.cancel() }
    }

    // MARK: Delegat zadania

    private final class TaskDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let host: String, username: String?, password: String?
        let sink: (@Sendable (Data) throws -> Void)?
        let onSent: (@Sendable (Int64) -> Void)?, onReceived: (@Sendable (Int64) -> Void)?
        let onBasicChallenge: @Sendable () -> Void
        private let lock = NSLock()
        private var task: URLSessionTask?
        private var cont: CheckedContinuation<DAVHTTPResult, Error>?
        private var response: HTTPURLResponse?
        private var buffer = Data()
        private var received: Int64 = 0
        private var authRejected = false
        private var sinkError: Error?
        private var cancelled = false

        init(host: String, username: String?, password: String?, sink: (@Sendable (Data) throws -> Void)?,
             onSent: (@Sendable (Int64) -> Void)?, onReceived: (@Sendable (Int64) -> Void)?, onBasicChallenge: @escaping @Sendable () -> Void) {
            self.host = host; self.username = username; self.password = password
            self.sink = sink; self.onSent = onSent; self.onReceived = onReceived; self.onBasicChallenge = onBasicChallenge
        }

        func start(task: URLSessionTask, continuation: CheckedContinuation<DAVHTTPResult, Error>) {
            lock.withLock { self.task = task; self.cont = continuation }
            task.delegate = self
        }

        func cancel() {
            let t = lock.withLock { () -> URLSessionTask? in cancelled = true; return task }
            t?.cancel()
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            let space = challenge.protectionSpace
            let method = space.authenticationMethod
            if method == NSURLAuthenticationMethodServerTrust { completionHandler(.performDefaultHandling, nil); return }   // standardowa weryfikacja certyfikatu
            guard method == NSURLAuthenticationMethodHTTPBasic || method == NSURLAuthenticationMethodHTTPDigest,
                  space.host.lowercased() == host, let u = username, let p = password else {
                completionHandler(.performDefaultHandling, nil); return   // bez poświadczeń: dostaniemy 401
            }
            if challenge.previousFailureCount > 0 {
                lock.withLock { authRejected = true }
                completionHandler(.cancelAuthenticationChallenge, nil); return
            }
            if method == NSURLAuthenticationMethodHTTPBasic { onBasicChallenge() }
            completionHandler(.useCredential, URLCredential(user: u, password: p, persistence: .none))
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)   // nie podążamy automatycznie — decyzję podejmuje `send`
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
            onSent?(totalBytesSent)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            lock.withLock { self.response = response as? HTTPURLResponse }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            let isError = lock.withLock { (response?.statusCode ?? 200) >= 300 }
            if let sink, !isError {
                do { try sink(data) } catch { lock.withLock { sinkError = error }; dataTask.cancel(); return }
            } else {
                // Treść błędów i Multi-Status trzymamy w pamięci, z limitem.
                let over = lock.withLock { () -> Bool in
                    if buffer.count + data.count > DAVHTTPClient.maxBufferedBody { return true }
                    buffer.append(data); return false
                }
                if over { lock.withLock { sinkError = NetworkError.invalidResponse("odpowiedź serwera jest zbyt duża") }; dataTask.cancel(); return }
            }
            let total = lock.withLock { received += Int64(data.count); return received }
            onReceived?(total)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            let (c, resp, buf, rejected, sinkErr, wasCancelled) = lock.withLock { (cont, response, buffer, authRejected, sinkError, cancelled) }
            guard let c else { return }
            lock.withLock { cont = nil }
            if let sinkErr { c.resume(throwing: sinkErr); return }
            if rejected { c.resume(throwing: NetworkError.authenticationFailed); return }
            if let error {
                c.resume(throwing: wasCancelled ? NetworkError.cancelled : DAVHTTPClient.map(error)); return
            }
            guard let resp else { c.resume(throwing: NetworkError.invalidResponse("brak odpowiedzi HTTP")); return }
            var headers: [String: String] = [:]
            for (k, v) in resp.allHeaderFields { if let k = k as? String, let v = v as? String { headers[k.lowercased()] = v } }
            c.resume(returning: DAVHTTPResult(status: resp.statusCode, headers: headers, body: buf))
        }
    }

    // MARK: Mapowanie błędów

    static func map(_ error: Error) -> NetworkError {
        if let n = error as? NetworkError { return n }
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return .connectionFailed(Redactor.redact(ns.localizedDescription, secrets: [])) }
        switch ns.code {
        case NSURLErrorCancelled: return .cancelled
        case NSURLErrorTimedOut: return .timeout
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return .dnsFailure(host: (ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL)?.host ?? "?")
        case NSURLErrorNetworkConnectionLost: return .connectionLost
        case NSURLErrorNotConnectedToInternet, NSURLErrorCannotConnectToHost, NSURLErrorInternationalRoamingOff, NSURLErrorDataNotAllowed:
            return .connectionFailed("nie można nawiązać połączenia z serwerem (sprawdź adres, port i sieć).")
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid, NSURLErrorClientCertificateRejected,
             NSURLErrorClientCertificateRequired:
            return .tlsCertificateInvalid(ns.code == NSURLErrorServerCertificateHasBadDate ? "certyfikat wygasł lub jeszcze nie obowiązuje."
                : ns.code == NSURLErrorServerCertificateUntrusted || ns.code == NSURLErrorServerCertificateHasUnknownRoot ? "certyfikat nie jest zaufany (nieznany wystawca lub samopodpisany)."
                : "nie udało się ustanowić bezpiecznego połączenia (TLS).")
        case NSURLErrorAppTransportSecurityRequiresSecureConnection:
            return .insecureConnectionRefused("system zablokował nieszyfrowane połączenie HTTP.")
        case NSURLErrorUserAuthenticationRequired, NSURLErrorUserCancelledAuthentication: return .authenticationFailed
        default: return .connectionFailed(Redactor.redact(ns.localizedDescription, secrets: []))
        }
    }
}
