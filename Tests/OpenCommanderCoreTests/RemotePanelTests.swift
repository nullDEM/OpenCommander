import XCTest
@testable import OpenCommanderCore

@MainActor
final class RemotePanelTests: XCTestCase {
    var provider: FakeProvider!
    var manager: ConnectionManager!
    var profileA: ConnectionProfile!

    override func setUp() async throws {
        provider = FakeProvider()
        provider.seedFile("/docs/raport #1 (100%).txt", "abc")
        provider.seedFile("/docs/zażółć gęślą.txt", "x")
        provider.seedDir("/docs/pod")
        let defaults = UserDefaults(suiteName: "oc-rp-\(UUID().uuidString)")!
        manager = ConnectionManager(profileStore: ProfileStore(defaults: defaults, key: "p"), secrets: InMemorySecretStore(),
                                    trustedHostsStore: TrustedHostsStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("oc-rp-\(UUID().uuidString)/h.json")))
        let p = provider!
        manager.providerFactory = { _, _ in p }
        profileA = try manager.save(ConnectionProfile(name: "Test", proto: .sftp, host: "h.test", username: "u", auth: .password), password: "x")
    }

    private func panel() -> PanelState {
        let m = manager!
        let p = PanelState(side: .left, location: URL(fileURLWithPath: NSTemporaryDirectory()))
        p.remoteLister = { loc in try await m.listing(loc) }
        return p
    }

    func testNavigatingToRemoteListsEntriesWithEncodedIdentityAndNoLocalWatcher() async throws {
        let p = panel()
        let loc = RemoteLocation(connectionID: profileA.id, path: RemotePath(parsing: "/docs"))
        p.navigate(to: loc.url); await p.waitUntilIdle()
        XCTAssertTrue(p.isRemote)
        XCTAssertNil(p.loadError)
        XCTAssertEqual(Set(p.entries.map(\.name)), ["raport #1 (100%).txt", "zażółć gęślą.txt", "pod"])
        for e in p.entries {
            XCTAssertEqual(e.url.scheme, "ocremote")
            XCTAssertFalse(e.url.isFileURL)
            XCTAssertEqual(e.url.remoteLocation?.path.lastComponent, e.name, "nazwa przeżywa kodowanie (spacje, #, %, Unicode)")
        }
        XCTAssertNil(p.freeSpace)
    }

    func testGoUpFromRemoteFolderSelectsChildAndStopsAtRoot() async throws {
        let p = panel()
        let loc = RemoteLocation(connectionID: profileA.id, path: RemotePath(parsing: "/docs"))
        p.navigate(to: loc.url); await p.waitUntilIdle()
        XCTAssertTrue(p.canGoUp)
        p.goUp(); await p.waitUntilIdle()
        XCTAssertEqual(p.location.remoteLocation?.path, .root)
        XCTAssertEqual(p.selection, [loc.url.absoluteString], "po wyjściu w górę zaznaczony jest folder, z którego wyszliśmy")
        XCTAssertFalse(p.canGoUp, "nie wychodzimy z korzenia serwera na dysk lokalny")
    }

    func testBackHistoryWorksAcrossLocalAndRemote() async throws {
        let p = panel()
        let local = p.location
        p.navigate(to: RemoteLocation(connectionID: profileA.id, path: .root).url); await p.waitUntilIdle()
        XCTAssertTrue(p.canGoBack)
        p.goBack(); await p.waitUntilIdle()
        XCTAssertEqual(p.location, local)
        XCTAssertFalse(p.isRemote)
    }

    func testSamePathOnTwoServersAreDifferentLocationsAndEntries() async throws {
        let other = try manager.save(ConnectionProfile(name: "Drugi", proto: .sftp, host: "h2.test", username: "u"), password: "y")
        let a = RemoteLocation(connectionID: profileA.id, path: RemotePath(parsing: "/docs"))
        let b = RemoteLocation(connectionID: other.id, path: RemotePath(parsing: "/docs"))
        XCTAssertNotEqual(a.url, b.url)
        let ea = try await manager.listing(a), eb = try await manager.listing(b)
        XCTAssertTrue(Set(ea.map(\.id)).isDisjoint(with: Set(eb.map(\.id))), "ta sama ścieżka na dwóch serwerach to różne elementy")
    }

    func testListingFailureIsShownAsReadableErrorAndDoesNotChangeLocation() async throws {
        let p = panel()
        let before = p.location
        p.navigate(to: RemoteLocation(connectionID: profileA.id, path: RemotePath(parsing: "/nie-ma")).url); await p.waitUntilIdle()
        XCTAssertNotNil(p.loadError)
        XCTAssertEqual(p.location, before)
        XCTAssertTrue(p.loadError!.localizedDescription.contains("nie istnieje"), p.loadError!.localizedDescription)
    }

    func testRemoteWithoutListerFailsSafely() async throws {
        let p = PanelState(side: .left, location: URL(fileURLWithPath: NSTemporaryDirectory()))
        p.navigate(to: RemoteLocation(connectionID: profileA.id, path: .root).url); await p.waitUntilIdle()
        XCTAssertNotNil(p.loadError)
    }

    func testRecursiveSearchIsNotUsedOnRemotePanel() async throws {
        let p = panel()
        p.navigate(to: RemoteLocation(connectionID: profileA.id, path: RemotePath(parsing: "/docs")).url); await p.waitUntilIdle()
        p.filterText = "raport"
        XCTAssertFalse(p.isRecursiveSearch)
        XCTAssertEqual(p.visibleEntries.count, 1, "filtr nazwy działa na bieżącym listingu")
    }

    func testPanelSettingsNeverPersistRemoteURLs() async throws {
        let tabs = PanelTabs(side: .left, settings: [PanelSettings(path: NSTemporaryDirectory(), sortKey: .name, sortAscending: true)],
                             activeIndex: 0) { s in
            let p = PanelState(side: .left, location: URL(fileURLWithPath: s.path)); return p
        }
        tabs.active.navigate(to: RemoteLocation(connectionID: profileA.id, path: .root).url)
        await tabs.active.waitUntilIdle()
        XCTAssertTrue(tabs.snapshot.allSatisfy { !$0.path.contains("ocremote") })
    }
}
