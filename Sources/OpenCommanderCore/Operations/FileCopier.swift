import Foundation
import Darwin

/// Kopiowanie przez `copyfile(3)`: metadane, klonowanie APFS (gdy możliwe), postęp w bajtach
/// i przerwanie w środku pliku. Dowiązania symboliczne są kopiowane jako dowiązania.
enum FileCopier {
    private final class Context {
        var lastCopied: off_t = 0
        var done: Int64 = 0
        var cancelled = false
        let onBytes: (Int64) -> Void
        init(_ onBytes: @escaping (Int64) -> Void) { self.onBytes = onBytes }
    }

    /// Rzuca `CancellationError` po anulowaniu albo `NSError` (POSIX) przy błędzie.
    /// `onBytes` dostaje łączną liczbę bajtów skopiowanych w tym wywołaniu (tylko gdy dane są faktycznie kopiowane;
    /// przy klonowaniu postępu nie ma, bo operacja jest natychmiastowa).
    static func copy(from src: URL, to dst: URL, allowClone: Bool = true, onBytes: @escaping (Int64) -> Void) throws {
        guard let state = copyfile_state_alloc() else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOMEM)) }
        defer { copyfile_state_free(state) }
        let ctx = Context(onBytes)

        let callback: copyfile_callback_t = { what, stage, state, _, _, ctxPtr in
            guard let ctxPtr else { return Int32(COPYFILE_CONTINUE) }
            let ctx = Unmanaged<Context>.fromOpaque(ctxPtr).takeUnretainedValue()
            if Task.isCancelled { ctx.cancelled = true; return Int32(COPYFILE_QUIT) }
            if what == Int32(COPYFILE_RECURSE_ERROR) { return Int32(COPYFILE_QUIT) }
            if stage == Int32(COPYFILE_START) { ctx.lastCopied = 0 }
            if what == Int32(COPYFILE_COPY_DATA), stage == Int32(COPYFILE_PROGRESS) {
                var copied: off_t = 0
                copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied)
                ctx.done += Int64(copied - ctx.lastCopied)
                ctx.lastCopied = copied
                ctx.onBytes(ctx.done)
            }
            return Int32(COPYFILE_CONTINUE)
        }
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(callback, to: UnsafeRawPointer.self))
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), Unmanaged.passUnretained(ctx).toOpaque())

        var flags = COPYFILE_ACL | COPYFILE_STAT | COPYFILE_XATTR | COPYFILE_DATA
            | COPYFILE_RECURSIVE | COPYFILE_NOFOLLOW_SRC | COPYFILE_EXCL
        if allowClone { flags |= COPYFILE_CLONE }
        let rc = copyfile(src.path, dst.path, state, copyfile_flags_t(flags))
        if rc != 0 {
            let err = errno
            if ctx.cancelled || Task.isCancelled { throw CancellationError() }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err))
        }
    }

    /// Suma rozmiarów plików (metadane; bez czytania zawartości i bez podążania za dowiązaniami).
    static func totalBytes(of url: URL) -> Int64 {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path) else { return 0 }
        if (attrs[.type] as? FileAttributeType) != .typeDirectory {
            return (attrs[.size] as? NSNumber)?.int64Value ?? 0
        }
        guard let en = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var sum: Int64 = 0
        for case let u as URL in en {
            if Task.isCancelled { break }
            let v = try? u.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true { sum += Int64(v?.fileSize ?? 0) }
        }
        return sum
    }
}
