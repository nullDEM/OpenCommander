import SwiftUI
import CoreTransferable
import UniformTypeIdentifiers

/// Ładunek przeciągania między panelami (lista adresów); nie opuszcza aplikacji.
struct DraggedFiles: Codable, Transferable {
    let urls: [URL]
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json)
    }
}
