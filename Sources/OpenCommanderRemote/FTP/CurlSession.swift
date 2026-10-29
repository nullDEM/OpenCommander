import Foundation
import CCurl
import OpenCommanderCore

/// Pojedyncza operacja libcurl: bufory błędów, ujście danych, źródło danych, postęp i przechwycone odpowiedzi serwera.
/// Przechwytujemy wyłącznie wiersze „serwer → klient” (CURLINFO_HEADER_IN); polecenia wysyłane do serwera (z hasłem)
/// nigdy nie są zapisywane ani logowane.
final class CurlOperation {
    let token: CancelToken
    var sink: ((UnsafeRawBufferPointer) -> Bool)?
    var source: ((UnsafeMutableRawBufferPointer) -> Int)?
    var onProgress: (@Sendable (Int64) -> Void)?
    var serverLines: [String] = []
    /// Bufor błędu libcurl; wskaźnik musi być stabilny przez cały `curl_easy_perform`, więc nie jest to tablica Swifta.
    private let errorBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: Int(CURL_ERROR_SIZE) + 1)
    var received: Int64 = 0

    init(token: CancelToken) {
        self.token = token
        errorBuffer.initialize(repeating: 0, count: Int(CURL_ERROR_SIZE) + 1)
    }
    deinit { errorBuffer.deallocate() }
    var errorBufferPointer: UnsafeMutablePointer<CChar> { errorBuffer }

    /// Ostatni trzycyfrowy kod odpowiedzi serwera (np. 550) i jego wiersz.
    var lastReply: (code: Int, line: String)? {
        for line in serverLines.reversed() where line.count >= 3 {
            if let code = Int(line.prefix(3)), line.count == 3 || line.dropFirst(3).first == " " { return (code, line) }
        }
        return nil
    }
    var errorText: String { String(cString: errorBuffer) }
}

final class CancelToken: @unchecked Sendable {
    private let lock = NSLock(); private var flag = false
    func cancel() { lock.withLock { flag = true } }
    var isCancelled: Bool { lock.withLock { flag } }
}

/// Uchwyt `CURL*` używany wyłącznie z jednej kolejki szeregowej. `curl_easy_reset` zachowuje otwarte połączenie,
/// więc kolejne operacje korzystają z tej samej sesji FTP (bez ponownego logowania i uzgadniania TLS).
final class CurlHandle {
    private static let globalInit: Void = { curl_global_init(Int(CURL_GLOBAL_DEFAULT)); return () }()
    private var h: UnsafeMutableRawPointer?

    init() throws {
        _ = Self.globalInit
        guard let h = curl_easy_init() else { throw NetworkError.other("nie udało się zainicjować libcurl") }
        self.h = h
    }

    deinit { if let h { curl_easy_cleanup(h) } }

    func close() { if let h { curl_easy_cleanup(h) }; h = nil }

    /// Wykonuje żądanie ze świeżą konfiguracją. `configure` ustawia URL, protokół i dane; zwraca kod libcurl.
    func perform(_ op: CurlOperation, configure: (CurlConfig) -> Void) -> Int {
        guard let h else { return Int(CURLE_FAILED_INIT.rawValue) }
        curl_easy_reset(h)
        let cfg = CurlConfig(h)
        let opPtr = Unmanaged.passUnretained(op).toOpaque()

        _ = oc_set_write_cb(h, { ptr, size, nmemb, ud in
            guard let ud else { return 0 }
            let op = Unmanaged<CurlOperation>.fromOpaque(ud).takeUnretainedValue()
            let n = size * nmemb
            guard let sink = op.sink, let ptr else { return n }
            return sink(UnsafeRawBufferPointer(start: ptr, count: n)) ? n : 0
        }, opPtr)
        _ = oc_set_read_cb(h, { ptr, size, nmemb, ud in
            guard let ud, let ptr else { return Int(CURL_READFUNC_ABORT) }
            let op = Unmanaged<CurlOperation>.fromOpaque(ud).takeUnretainedValue()
            guard let source = op.source else { return 0 }
            return source(UnsafeMutableRawBufferPointer(start: ptr, count: size * nmemb))
        }, opPtr)
        _ = oc_set_xfer_cb(h, { ud, dltotal, dlnow, ultotal, ulnow in
            guard let ud else { return 1 }
            let op = Unmanaged<CurlOperation>.fromOpaque(ud).takeUnretainedValue()
            if op.token.isCancelled { return 1 }   // przerwanie transferu
            let now = Int64(max(dlnow, ulnow))
            if now != op.received { op.received = now; op.onProgress?(now) }
            return 0
        }, opPtr)
        cfg.long(CURLOPT_NOPROGRESS, 0)
        // Tylko odpowiedzi serwera (CURLINFO_HEADER_IN == 1); reszta debugu jest odrzucana.
        _ = oc_set_debug_cb(h, { _, type, data, size, ud in
            guard type == CURLINFO_HEADER_IN, let ud, let data else { return 0 }
            let op = Unmanaged<CurlOperation>.fromOpaque(ud).takeUnretainedValue()
            if op.serverLines.count < 400 {
                let line = String(decoding: UnsafeRawBufferPointer(start: data, count: size), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !line.isEmpty { op.serverLines.append(line) }
            }
            return 0
        }, opPtr)
        cfg.long(CURLOPT_VERBOSE, 1)
        cfg.long(CURLOPT_NOSIGNAL, 1)
        cfg.long(CURLOPT_FOLLOWLOCATION, 0)
        cfg.str(CURLOPT_PROTOCOLS_STR, "ftp,ftps")

        configure(cfg)
        _ = oc_setopt_ptr(h, CURLOPT_ERRORBUFFER, op.errorBufferPointer)
        let rc: CURLcode = curl_easy_perform(h)
        _ = oc_setopt_ptr(h, CURLOPT_ERRORBUFFER, nil)   // uchwyt przeżywa operację — nie zostawiamy wskaźnika do zwolnionej pamięci
        cfg.releaseLists()
        return Int(rc.rawValue)
    }

    func infoOff(_ info: CURLINFO) -> Int64? {
        guard let h else { return nil }
        var v: curl_off_t = -1
        return oc_getinfo_off(h, info, &v) == CURLE_OK ? Int64(v) : nil
    }
}

/// Cienka nakładka na `curl_easy_setopt` (wartości o konkretnych typach). Listy `curl_slist` są zwalniane po `perform`.
final class CurlConfig {
    private let h: UnsafeMutableRawPointer
    private var lists: [UnsafeMutablePointer<curl_slist>] = []
    private var strings: [UnsafeMutablePointer<CChar>] = []
    init(_ h: UnsafeMutableRawPointer) { self.h = h }

    func long(_ opt: CURLoption, _ v: Int) { _ = oc_setopt_long(h, opt, v) }
    func off(_ opt: CURLoption, _ v: Int64) { _ = oc_setopt_off(h, opt, curl_off_t(v)) }
    /// libcurl kopiuje łańcuchy (CURLOPT_URL itd.), więc wystarczy tymczasowy wskaźnik.
    func str(_ opt: CURLoption, _ v: String) { v.withCString { _ = oc_setopt_str(h, opt, $0) } }
    func slist(_ opt: CURLoption, _ items: [String]) {
        var list: UnsafeMutablePointer<curl_slist>?
        for s in items { list = s.withCString { curl_slist_append(list, $0) } }
        if let list { lists.append(list); _ = oc_setopt_slist(h, opt, list) }
    }
    func releaseLists() { lists.forEach { curl_slist_free_all($0) }; lists.removeAll() }
}
