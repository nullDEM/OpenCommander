import Foundation
import Citadel
import Crypto
import NIOCore
import NIOSSH
@testable import OpenCommanderRemote
import OpenCommanderCore

/// Serwer SFTP w procesie testowym (Citadel), wystawiający wyłącznie katalog tymczasowy utworzony na potrzeby testu.
/// Słucha tylko na 127.0.0.1. Nie jest w pełni wiernym serwerem (np. nie raportuje błędu otwarcia pliku) —
/// służy do hermetycznych testów ścieżek poprawnych, uwierzytelniania i zaufania do klucza hosta.
final class TestSFTPServer: @unchecked Sendable {
    let root: URL
    let port: Int
    let username: String
    let password: String
    let hostKey: Curve25519.Signing.PrivateKey
    private let server: SSHServer

    static func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0); defer { close(fd) }
        var addr = sockaddr_in(); addr.sin_family = sa_family_t(AF_INET); addr.sin_addr.s_addr = inet_addr("127.0.0.1"); addr.sin_port = 0
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard ok == 0 else { throw NetworkError.other("bind") }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        return Int(UInt16(bigEndian: addr.sin_port))
    }

    static func start(root: URL, username: String = "ola", password: String = "tajne-haslo-123",
                      hostKey: Curve25519.Signing.PrivateKey = .init(), port: Int? = nil) async throws -> TestSFTPServer {
        let port = try port ?? freePort()
        let server = try await SSHServer.host(
            host: "127.0.0.1", port: port,
            hostKeys: [NIOSSHPrivateKey(ed25519Key: hostKey)],
            authenticationDelegate: PasswordAuth(username: username, password: password))
        server.enableSFTP(withDelegate: FSDelegate(root: root))
        return TestSFTPServer(root: root, port: port, username: username, password: password, hostKey: hostKey, server: server)
    }

    private init(root: URL, port: Int, username: String, password: String, hostKey: Curve25519.Signing.PrivateKey, server: SSHServer) {
        self.root = root; self.port = port; self.username = username; self.password = password; self.hostKey = hostKey; self.server = server
    }

    func stop() async { try? await server.close() }

    var hostKeyInfo: HostKeyInfo {
        HostKeyDelegate.info(for: NIOSSHPrivateKey(ed25519Key: hostKey).publicKey, host: "127.0.0.1", port: port)
    }
}

struct PasswordAuth: NIOSSHServerUserAuthenticationDelegate {
    let username: String
    let password: String
    var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods { .password }
    func requestReceived(request: NIOSSHUserAuthenticationRequest, responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
        if case .password(let p) = request.request, request.username == username, p.password == password {
            responsePromise.succeed(.success)
        } else {
            responsePromise.succeed(.failure)
        }
    }
}

struct FSDelegate: SFTPDelegate {
    let root: URL

    private func url(_ p: String) -> URL {
        RemotePath(parsing: p).components.reduce(root) { $0.appendingPathComponent($1) }
    }

    static func attrs(_ u: URL) throws -> SFTPFileAttributes {
        let a = try FileManager.default.attributesOfItem(atPath: u.path)
        let type = a[.type] as? FileAttributeType
        let typeBits: UInt32 = type == .typeDirectory ? 0o040000 : (type == .typeSymbolicLink ? 0o120000 : 0o100000)
        let perm = UInt32((a[.posixPermissions] as? NSNumber)?.uint32Value ?? 0o644)
        let mtime = (a[.modificationDate] as? Date) ?? Date()
        var out = SFTPFileAttributes(size: (a[.size] as? NSNumber)?.uint64Value ?? 0,
                                     accessModificationTime: .init(accessTime: mtime, modificationTime: mtime))
        out.permissions = typeBits | perm
        return out
    }

    func fileAttributes(atPath path: String, context: SSHContext) async throws -> SFTPFileAttributes {
        try Self.attrs(url(path).resolvingSymlinksInPath())   // stat: podąża za dowiązaniami
    }

    func openFile(_ filePath: String, withAttributes: SFTPFileAttributes, flags: SFTPOpenFileFlags, context: SSHContext) async throws -> SFTPFileHandle {
        let u = url(filePath)
        let fm = FileManager.default
        if flags.contains(.create) && !fm.fileExists(atPath: u.path) { fm.createFile(atPath: u.path, contents: nil) }
        let writing = flags.contains(.write)
        let h = writing ? try FileHandle(forUpdating: u) : try FileHandle(forReadingFrom: u)
        if flags.contains(.truncate) { try h.truncate(atOffset: 0) }
        return FSFileHandle(handle: h, url: u)
    }

    func removeFile(_ filePath: String, context: SSHContext) async throws -> SFTPStatusCode {
        do { try FileManager.default.removeItem(at: url(filePath)); return .ok } catch { return .failure }
    }
    func createDirectory(_ filePath: String, withAttributes: SFTPFileAttributes, context: SSHContext) async throws -> SFTPStatusCode {
        do { try FileManager.default.createDirectory(at: url(filePath), withIntermediateDirectories: false); return .ok } catch { return .failure }
    }
    func removeDirectory(_ filePath: String, context: SSHContext) async throws -> SFTPStatusCode {
        let u = url(filePath)
        guard (try? FileManager.default.contentsOfDirectory(atPath: u.path))?.isEmpty == true else { return .failure }
        do { try FileManager.default.removeItem(at: u); return .ok } catch { return .failure }
    }
    func realPath(for canonicalUrl: String, context: SSHContext) async throws -> [SFTPPathComponent] {
        let p = canonicalUrl == "." ? "/" : RemotePath(parsing: canonicalUrl).string
        return [SFTPPathComponent(filename: p, longname: p, attributes: .none)]
    }
    func openDirectory(atPath path: String, context: SSHContext) async throws -> SFTPDirectoryHandle { FSDirHandle(url: url(path)) }
    func setFileAttributes(to attributes: SFTPFileAttributes, atPath path: String, context: SSHContext) async throws -> SFTPStatusCode { .ok }
    func addSymlink(linkPath: String, targetPath: String, context: SSHContext) async throws -> SFTPStatusCode {
        do { try FileManager.default.createSymbolicLink(atPath: url(linkPath).path, withDestinationPath: url(targetPath).path); return .ok } catch { return .failure }
    }
    func readSymlink(atPath path: String, context: SSHContext) async throws -> [SFTPPathComponent] { [] }
    func rename(oldPath: String, newPath: String, flags: UInt32, context: SSHContext) async throws -> SFTPStatusCode {
        let to = url(newPath)
        guard !FileManager.default.fileExists(atPath: to.path) else { return .failure }   // jak OpenSSH: nie nadpisuje
        do { try FileManager.default.moveItem(at: url(oldPath), to: to); return .ok } catch { return .failure }
    }
}

final class FSFileHandle: SFTPFileHandle {
    let handle: FileHandle; let url: URL
    init(handle: FileHandle, url: URL) { self.handle = handle; self.url = url }
    func read(at offset: UInt64, length: UInt32) async throws -> ByteBuffer {
        try handle.seek(toOffset: offset)
        let data = try handle.read(upToCount: Int(min(length, 64 * 1024))) ?? Data()
        return ByteBuffer(data: data)
    }
    func write(_ data: ByteBuffer, atOffset offset: UInt64) async throws -> SFTPStatusCode {
        try handle.seek(toOffset: offset); try handle.write(contentsOf: Data(buffer: data)); return .ok
    }
    func close() async throws -> SFTPStatusCode { try? handle.close(); return .ok }
    func readFileAttributes() async throws -> SFTPFileAttributes { try FSDelegate.attrs(url) }
    func setFileAttributes(to attributes: SFTPFileAttributes) async throws {}
}

final class FSDirHandle: SFTPDirectoryHandle {
    let url: URL
    init(url: URL) { self.url = url }
    func listFiles(context: SSHContext) async throws -> [SFTPFileListing] {
        let names = try FileManager.default.contentsOfDirectory(atPath: url.path)
        let comps: [SFTPPathComponent] = names.sorted().compactMap { n in
            let u = url.appendingPathComponent(n)
            // lstat: dowiązania zgłaszamy jako dowiązania
            var attrs = (try? FSDelegate.attrs(u)) ?? .none
            if (try? u.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { attrs.permissions = 0o120777 }
            return SFTPPathComponent(filename: n, longname: n, attributes: attrs)
        }
        return [SFTPFileListing(path: comps)]
    }
}
