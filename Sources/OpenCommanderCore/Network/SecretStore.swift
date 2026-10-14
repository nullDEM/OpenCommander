import Foundation
import Security

/// Magazyn sekretów (haseł, passphrase). Produkcyjnie: Keychain; w testach: pamięć.
public protocol SecretStore: Sendable {
    func secret(for ref: SecretRef) throws -> String?
    func setSecret(_ value: String, for ref: SecretRef) throws
    func deleteSecret(for ref: SecretRef) throws
}

public struct SecretStoreError: Error, LocalizedError, Equatable {
    public let status: Int32
    public var errorDescription: String? {
        let msg = SecCopyErrorMessageString(status, nil) as String? ?? "kod \(status)"
        return "Błąd Keychain: \(msg)"
    }
}

/// Keychain systemowy (hasła ogólne, tylko to urządzenie, bez synchronizacji iCloud).
/// Konto = identyfikator `SecretRef`, więc nazwa serwera ani użytkownika nie trafia do atrybutów.
public struct KeychainSecretStore: SecretStore {
    public static let defaultService = "org.opencommander.OpenCommander.connections"
    let service: String

    public init(service: String = KeychainSecretStore.defaultService) { self.service = service }

    func baseQuery(_ ref: SecretRef) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: ref.id.uuidString,
         kSecAttrSynchronizable as String: false]
    }

    public func secret(for ref: SecretRef) throws -> String? {
        var q = baseQuery(ref)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw SecretStoreError(status: status) }
        return String(data: data, encoding: .utf8)
    }

    public func setSecret(_ value: String, for ref: SecretRef) throws {
        let data = Data(value.utf8)
        let update = SecItemUpdate(baseQuery(ref) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw SecretStoreError(status: update) }
        var add = baseQuery(ref)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw SecretStoreError(status: status) }
    }

    public func deleteSecret(for ref: SecretRef) throws {
        let status = SecItemDelete(baseQuery(ref) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SecretStoreError(status: status) }
    }
}

/// Magazyn w pamięci — do testów i do haseł „tylko na czas sesji” (nie zapisywanych nigdzie).
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SecretRef: String] = [:]
    public init() {}
    public func secret(for ref: SecretRef) throws -> String? { lock.withLock { values[ref] } }
    public func setSecret(_ value: String, for ref: SecretRef) throws { lock.withLock { values[ref] = value } }
    public func deleteSecret(for ref: SecretRef) throws { lock.withLock { _ = values.removeValue(forKey: ref) } }
    public var count: Int { lock.withLock { values.count } }
}
