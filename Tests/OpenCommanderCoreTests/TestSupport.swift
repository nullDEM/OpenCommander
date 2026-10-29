import Foundation
import XCTest
@testable import OpenCommanderCore

/// Fałszywy Kosz: przenosi do katalogu w obrębie sandboxu testu, nigdy do prawdziwego Kosza.
final class FakeTrasher: Trashing, @unchecked Sendable {
    let bin: URL
    var trashed: [URL] = []
    var shouldFail = false
    init(bin: URL) { self.bin = bin }
    func trash(_ url: URL) async throws {
        if shouldFail { throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError) }
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: bin.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent))
        trashed.append(url)
    }
}

class TempDirTestCase: XCTestCase {
    var root: URL!
    var bin: URL { root.appendingPathComponent("_bin") }

    override func setUpWithError() throws {
        // Fizyczna ścieżka (bez symlinku /var → /private/var), by porównania ścieżek były stabilne.
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
        root = base.appendingPathComponent("OpenCommanderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // chmod, żeby można było posprzątać po testach uprawnień.
        if let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let u as URL in e { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: u.path) }
        }
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func makeDir(_ rel: String) throws -> URL {
        let u = root.appendingPathComponent(rel, isDirectory: true)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    @discardableResult
    func makeFile(_ rel: String, _ content: String = "x") throws -> URL {
        let u = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.data(using: .utf8)!.write(to: u)
        return u
    }

    func read(_ u: URL) -> String? { try? String(contentsOf: u, encoding: .utf8) }
    func exists(_ u: URL) -> Bool { (try? FileManager.default.attributesOfItem(atPath: u.path)) != nil }
    func names(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }
}
