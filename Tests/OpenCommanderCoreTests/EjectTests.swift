import XCTest
@testable import OpenCommanderCore

final class EjectPolicyTests: XCTestCase {
    func v(_ path: String, internal i: Bool = false, ejectable e: Bool = true) -> VolumeInfo {
        VolumeInfo(url: URL(fileURLWithPath: path), name: (path as NSString).lastPathComponent, isInternal: i, isEjectable: e)
    }

    func testSystemAndNonEjectableVolumesCannotBeEjected() {
        XCTAssertFalse(v("/", internal: true, ejectable: true).canEject, "dysk systemowy nigdy")
        XCTAssertFalse(v("/System/Volumes/Data", ejectable: true).canEject)
        XCTAssertFalse(v("/Volumes/Wewnetrzny", internal: true, ejectable: false).canEject)
        XCTAssertTrue(v("/Volumes/Pendrive").canEject)
    }

    func testRealMountedRootIsNeverEjectable() {
        let root = Locations.mountedVolumes().filter { $0.url.path == "/" }
        XCTAssertTrue(root.allSatisfy { !$0.canEject })
    }

    func testIsInsideDoesNotMatchSiblingWithSamePrefix() {
        XCTAssertTrue(VolumeEjector.isInside("/Volumes/USB/a/b", volume: "/Volumes/USB"))
        XCTAssertTrue(VolumeEjector.isInside("/Volumes/USB", volume: "/Volumes/USB"))
        XCTAssertFalse(VolumeEjector.isInside("/Volumes/USB2/a", volume: "/Volumes/USB"), "USB2 to inny wolumin")
        XCTAssertTrue(VolumeEjector.isInside("/Users/x", volume: "/"))
    }

    func testVolumeContainingPicksDeepest() {
        let vols = [v("/", internal: true, ejectable: false), v("/Volumes/USB")]
        XCTAssertEqual(VolumeEjector.volume(containing: URL(fileURLWithPath: "/Volumes/USB/foto"), in: vols)?.name, "USB")
        XCTAssertEqual(VolumeEjector.volume(containing: URL(fileURLWithPath: "/Users/x"), in: vols)?.url.path, "/")
    }

    func testEjectRefusesNonEjectable() async {
        do { try await VolumeEjector.eject(v("/", internal: true, ejectable: false)); XCTFail("powinno odmówić") }
        catch { guard case .ejectFailed = error as? OperationError else { return XCTFail("zły błąd \(error)") } }
    }
}

/// Prawdziwe wysunięcie — wyłącznie na WŁASNYM, tymczasowym obrazie dysku (nie na urządzeniach użytkownika).
final class EjectDiskImageTests: TempDirTestCase {
    private func hdiutil(_ args: [String]) throws -> (Int32, String) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil"); p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        try p.run(); p.waitUntilExit()
        return (p.terminationStatus, String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
    }

    private func attachImage() throws -> (VolumeInfo, mount: URL) {
        let dmg = root.appendingPathComponent("oc-test.dmg")
        let mount = root.appendingPathComponent("mnt")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        var r = try hdiutil(["create", "-size", "8m", "-fs", "APFS", "-volname", "OCEjectTest", dmg.path])
        try XCTSkipIf(r.0 != 0, "hdiutil create niedostępny: \(r.1)")
        r = try hdiutil(["attach", "-nobrowse", "-mountpoint", mount.path, dmg.path])
        try XCTSkipIf(r.0 != 0, "hdiutil attach niedostępny: \(r.1)")
        let vol = VolumeInfo(url: mount, name: "OCEjectTest", isInternal: false, isEjectable: true)
        return (vol, mount)
    }

    func testEjectsOwnDiskImage() async throws {
        let (vol, mount) = try attachImage()
        defer { _ = try? hdiutil(["detach", "-force", mount.path]) }
        try "dane".write(to: mount.appendingPathComponent("plik.txt"), atomically: true, encoding: .utf8)
        // Obraz z -nobrowse jest „ukryty”, więc sprawdzamy pełną listę montowań (bez pomijania ukrytych).
        func isMounted() -> Bool {
            let all = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? []
            return all.contains { $0.resolvingSymlinksInPath().path == mount.resolvingSymlinksInPath().path }
        }
        XCTAssertTrue(isMounted(), "przedwarunek: obraz jest zamontowany")
        try await VolumeEjector.eject(vol)
        XCTAssertFalse(isMounted(), "wolumin został odmontowany")
    }

    func testEjectFailsWhenVolumeBusyAndLeavesDataIntact() async throws {
        let (vol, mount) = try attachImage()
        defer { _ = try? hdiutil(["detach", "-force", mount.path]) }
        let file = mount.appendingPathComponent("zajety.txt")
        try "ważne".write(to: file, atomically: true, encoding: .utf8)
        let handle = try FileHandle(forReadingFrom: file) // otwarty plik = wolumin zajęty
        defer { try? handle.close() }
        do { try await VolumeEjector.eject(vol); XCTFail("zajęty wolumin nie powinien się wysunąć") }
        catch { guard case .ejectFailed(let name, _) = error as? OperationError else { return XCTFail("\(error)") }; XCTAssertEqual(name, "OCEjectTest") }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "ważne", "dane nietknięte po nieudanym wysunięciu")
    }
}
