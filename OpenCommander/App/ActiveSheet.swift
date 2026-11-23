import Foundation
import OpenCommanderCore

enum ActiveSheet: Identifiable {
    case newFolder
    case rename(FileEntry)
    case saveWorkspace
    case batchRename([FileEntry])
    case compareFolders
    case duplicates(URL)
    case connections
    case editConnection(ConnectionProfile?)
    case trustedHosts

    var id: String {
        switch self {
        case .saveWorkspace: return "saveWorkspace"
        case .batchRename: return "batchRename"
        case .compareFolders: return "compare"
        case .duplicates(let u): return "dups-\(u.path)"
        case .connections: return "connections"
        case .editConnection(let p): return "edit-\(p?.id.uuidString ?? "new")"
        case .trustedHosts: return "trustedHosts"
        case .newFolder: return "newFolder"
        case .rename(let e): return "rename-\(e.id)"
        }
    }
}
