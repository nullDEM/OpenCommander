import Foundation
import Testing
@testable import OpenCommanderCore

@MainActor
struct PanelSortComparatorsTests {
    let dir: TemporaryDirectory

    init() throws {
        dir = try TemporaryDirectory()
    }

    /// Komparator zbudowany dla klucza i kierunku — tak jak robi to tabela po kliknięciu nagłówka kolumny.
    private static func comparator(for key: SortKey, ascending: Bool) -> KeyPathComparator<FileEntry> {
        let order: SortOrder = ascending ? .forward : .reverse
        switch key {
        case .name: return KeyPathComparator(\FileEntry.name, order: order)
        case .size: return KeyPathComparator(\FileEntry.sortSize, order: order)
        case .kind: return KeyPathComparator(\FileEntry.kind, order: order)
        case .date: return KeyPathComparator(\FileEntry.sortDate, order: order)
        }
    }

    @Test(arguments: [SortKey.name, .size, .kind, .date], [true, false])
    func comparatorsRoundTripThroughSetSort(key: SortKey, ascending: Bool) {
        let panel = PanelState(side: .left, location: dir.root)
        panel.sortComparators = [Self.comparator(for: key, ascending: ascending)]

        #expect(panel.sortKey == key)
        #expect(panel.sortAscending == ascending)
        #expect(panel.sortComparators.first?.order == (ascending ? .forward : .reverse))
    }

    @Test func emptyComparatorListIsIgnored() {
        let panel = PanelState(side: .left, location: dir.root, sortKey: .size, sortAscending: false)
        panel.sortComparators = []
        #expect(panel.sortKey == .size)
        #expect(panel.sortAscending == false)
    }
}

struct ConnectionProfileTextAccessorsTests {
    @Test func optionalFieldsAreExposedAsText() {
        var profile = ConnectionProfile(name: "x", proto: .webdav, baseURL: nil)
        #expect(profile.baseURLText == "")
        #expect(profile.keyFilePathText == "")

        profile.baseURLText = "https://serwer/dav"
        profile.keyFilePathText = "/klucz"
        #expect(profile.baseURL == "https://serwer/dav")
        #expect(profile.keyFilePath == "/klucz")

        profile.baseURLText = ""
        #expect(profile.baseURL == "", "pusty tekst zapisuje pusty adres, jak dotychczasowy Binding w formularzu")
    }
}
