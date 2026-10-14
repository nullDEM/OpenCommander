import Foundation
import OpenCommanderCore

/// Parsowanie listingów FTP.
/// - MLSD (RFC 3659) jest ustrukturyzowany i jednoznaczny — to preferowane źródło.
/// - LIST nie ma standardu: obsługujemy tylko dwa popularne formaty (unixowy `ls -l` i DOS/IIS). Wiersze w innym formacie są
///   pomijane i liczone w `skipped`; daty „Mon dd HH:mm” nie niosą roku (zakładamy bieżący lub poprzedni), więc są przybliżone.
enum FTPListParser {
    static let maxEntries = 200_000
    static let maxBytes = 64 * 1024 * 1024

    struct Result: Equatable {
        var entries: [RemoteEntry] = []
        var skipped = 0
        var truncated = false
    }

    /// Nazwa z serwera jest niezaufana: nie może zawierać separatora, znaków sterujących ani być „.”/„..”.
    static func isSafeName(_ name: String) -> Bool {
        RemotePath.isValidName(name) && !name.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }

    // MARK: MLSD

    static func parseMLSD(_ text: String) -> Result {
        var r = Result()
        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if line.isEmpty { continue }
            if r.entries.count >= maxEntries { r.truncated = true; break }
            // „fakt=wartość;fakt=wartość; nazwa” — nazwa po pierwszej spacji (może zawierać spacje i „;”).
            guard let space = line.firstIndex(of: " ") else { r.skipped += 1; continue }
            let facts = line[..<space], name = String(line[line.index(after: space)...])
            var dict: [String: String] = [:]
            for f in facts.split(separator: ";") {
                if let eq = f.firstIndex(of: "=") { dict[f[..<eq].lowercased()] = String(f[f.index(after: eq)...]) }
            }
            let type = (dict["type"] ?? "").lowercased()
            if type == "cdir" || type == "pdir" { continue }
            guard isSafeName(name) else { r.skipped += 1; continue }
            let kind: RemoteEntryKind
            switch type {
            case "file": kind = .file
            case "dir": kind = .directory
            case let t where t.hasPrefix("os.unix=slink") || t.hasPrefix("os.unix=symlink"): kind = .symlink
            case "": r.skipped += 1; continue
            default: kind = .other
            }
            let size = dict["size"].flatMap(Int64.init)
            r.entries.append(RemoteEntry(name: name, kind: kind, size: kind == .file ? size : nil,
                                         modified: dict["modify"].flatMap(parseMLSTTime),
                                         permissions: dict["unix.mode"] ?? dict["perm"]))
        }
        return r
    }

    /// `YYYYMMDDHHMMSS[.sss]` w UTC.
    static func parseMLSTTime(_ s: String) -> Date? {
        let digits = s.split(separator: ".").first.map(String.init) ?? s
        guard digits.count == 14, digits.allSatisfy(\.isNumber) else { return nil }
        var c = DateComponents(); c.timeZone = TimeZone(identifier: "UTC")
        let a = Array(digits)
        func n(_ r: Range<Int>) -> Int { Int(String(a[r]))! }
        c.year = n(0..<4); c.month = n(4..<6); c.day = n(6..<8); c.hour = n(8..<10); c.minute = n(10..<12); c.second = n(12..<14)
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: c)
    }

    // MARK: LIST (unixowy i DOS)

    private static let unixRegex = try! NSRegularExpression(
        pattern: #"^([\-dlcbps])([rwxsStT\-]{9})[+@.]?\s+\d+\s+\S+\s+\S+\s+(\d+)\s+(\w{3})\s+(\d{1,2})\s+(\d{4}|\d{1,2}:\d{2})\s+(.+)$"#)
    private static let unixNoGroupRegex = try! NSRegularExpression(
        pattern: #"^([\-dlcbps])([rwxsStT\-]{9})[+@.]?\s+\d+\s+\S+\s+(\d+)\s+(\w{3})\s+(\d{1,2})\s+(\d{4}|\d{1,2}:\d{2})\s+(.+)$"#)
    private static let dosRegex = try! NSRegularExpression(
        pattern: #"^(\d{2})-(\d{2})-(\d{2,4})\s+(\d{1,2}):(\d{2})\s*([AP]M)?\s+(<DIR>|\d+)\s+(.+)$"#)

    static func parseLIST(_ text: String, now: Date = Date()) -> Result {
        var r = Result()
        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if line.isEmpty || line.hasPrefix("total ") { continue }
            if r.entries.count >= maxEntries { r.truncated = true; break }
            if let e = parseUnix(line, now: now) ?? parseDOS(line) {
                if e.name == "." || e.name == ".." { continue }
                if isSafeName(e.name) { r.entries.append(e) } else { r.skipped += 1 }
            } else { r.skipped += 1 }
        }
        return r
    }

    private static func groups(_ re: NSRegularExpression, _ line: String) -> [String]? {
        let ns = line as NSString
        guard let m = re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (1..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
    }

    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    private static func parseUnix(_ line: String, now: Date) -> RemoteEntry? {
        guard let g = groups(unixRegex, line) ?? groups(unixNoGroupRegex, line) else { return nil }
        let kind: RemoteEntryKind = g[0] == "d" ? .directory : (g[0] == "l" ? .symlink : (g[0] == "-" ? .file : .other))
        var name = g[6]
        if kind == .symlink, let r = name.range(of: " -> ") { name = String(name[..<r.lowerBound]) }
        return RemoteEntry(name: name, kind: kind, size: kind == .file ? Int64(g[2]) : nil,
                           modified: unixDate(month: g[3], day: g[4], yearOrTime: g[5], now: now), permissions: g[1])
    }

    private static func unixDate(month: String, day: String, yearOrTime: String, now: Date) -> Date? {
        guard let mi = months.firstIndex(of: month.lowercased()), let d = Int(day) else { return nil }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        var c = DateComponents(); c.timeZone = cal.timeZone; c.month = mi + 1; c.day = d
        if yearOrTime.contains(":") {
            let t = yearOrTime.split(separator: ":"); c.hour = Int(t[0]); c.minute = Int(t[1])
            let year = cal.component(.year, from: now); c.year = year
            // Bez roku: jeśli data wypadłaby w przyszłości, to chodzi o rok poprzedni.
            if let date = cal.date(from: c), date > now.addingTimeInterval(24 * 3600) { c.year = year - 1 }
        } else { c.year = Int(yearOrTime) }
        return cal.date(from: c)
    }

    private static func parseDOS(_ line: String) -> RemoteEntry? {
        guard let g = groups(dosRegex, line) else { return nil }
        var year = Int(g[2])!; if g[2].count == 2 { year += year < 70 ? 2000 : 1900 }
        var hour = Int(g[3])!
        if g[5] == "PM", hour < 12 { hour += 12 }; if g[5] == "AM", hour == 12 { hour = 0 }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let date = cal.date(from: DateComponents(timeZone: cal.timeZone, year: year, month: Int(g[0]), day: Int(g[1]), hour: hour, minute: Int(g[4])))
        let isDir = g[6] == "<DIR>"
        return RemoteEntry(name: g[7], kind: isDir ? .directory : .file, size: isDir ? nil : Int64(g[6]), modified: date)
    }
}
