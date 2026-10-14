import Foundation
import OpenCommanderCore

/// Punkt wejścia modułu protokołów: fabryka providerów dla `ConnectionManager`.
public enum RemoteModule {
    /// Protokoły faktycznie zaimplementowane — tylko je pokazuje formularz (żadnych atrap).
    public static let supportedProtocols: [ConnectionProtocol] = [.sftp, .ftps, .webdav, .ftp]

    public static func makeProvider(_ profile: ConnectionProfile, _ context: ProviderContext) throws -> any FileProvider {
        switch profile.proto {
        case .sftp: return SFTPProvider(profile: profile, context: context)
        case .webdav: return try WebDAVProvider(profile: profile, context: context)
        case .ftp, .ftps: return try FTPProvider(profile: profile, context: context)
        }
    }

    @MainActor public static func install(in manager: ConnectionManager) {
        manager.providerFactory = { try makeProvider($0, $1) }
    }
}
