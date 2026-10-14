import Foundation
import Observation

/// Sekrety potrzebne do jednego połączenia (żyją tylko w pamięci na czas łączenia).
public struct ConnectionCredentials: Sendable {
    public var password: String?
    public var passphrase: String?
    public init(password: String? = nil, passphrase: String? = nil) { self.password = password; self.passphrase = passphrase }
    public var allSecrets: [String] { [password, passphrase].compactMap { $0 } }
}

/// Wszystko, czego provider potrzebuje poza profilem.
public struct ProviderContext: Sendable {
    public let credentials: ConnectionCredentials
    public let hostKeyVerifier: HostKeyVerifier
}

public enum CredentialKind: Sendable { case password, passphrase }

/// Zarządza zapisanymi profilami i sesjami. Odpowiada za Keychain, hasła tylko na sesję, ponowne łączenie
/// i test połączenia. Niczego nie loguje — komunikaty błędów przechodzą przez `Redactor`.
@MainActor @Observable
public final class ConnectionManager {
    public enum State: Equatable, Sendable {
        case disconnected, connecting, connected
        case failed(String)
    }

    public private(set) var profiles: [ConnectionProfile]
    public private(set) var states: [UUID: State] = [:]

    @ObservationIgnored private let profileStore: ProfileStore
    @ObservationIgnored public let secrets: any SecretStore
    @ObservationIgnored private let sessionSecrets = InMemorySecretStore()
    @ObservationIgnored private var sessionRefs: [UUID: SecretRef] = [:]
    @ObservationIgnored private var sessionPassphraseRefs: [UUID: SecretRef] = [:]
    @ObservationIgnored private var providers: [UUID: any FileProvider] = [:]
    @ObservationIgnored private var connecting: [UUID: Task<any FileProvider, Error>] = [:]
    @ObservationIgnored public let trustedHostsStore: TrustedHostsStore

    /// Ustawiane przez moduł protokołów (SFTP/FTP/WebDAV).
    @ObservationIgnored public var providerFactory: (@Sendable (ConnectionProfile, ProviderContext) throws -> any FileProvider)?
    /// Pytanie o hasło/passphrase, gdy nie jest zapisane. `nil` = użytkownik anulował.
    @ObservationIgnored public var credentialPrompt: (@MainActor (ConnectionProfile, CredentialKind) async -> String?)?
    /// Pytanie o zaufanie do nieznanego klucza hosta. `false` = odrzucono.
    @ObservationIgnored public var hostKeyPrompt: (@MainActor (HostKeyInfo) async -> Bool)?

    public init(profileStore: ProfileStore = ProfileStore(), secrets: any SecretStore = KeychainSecretStore(),
                trustedHostsStore: TrustedHostsStore = TrustedHostsStore(url: TrustedHostsStore.defaultURL())) {
        self.profileStore = profileStore
        self.secrets = secrets
        self.trustedHostsStore = trustedHostsStore
        self.profiles = profileStore.load()
    }

    public func profile(_ id: UUID) -> ConnectionProfile? { profiles.first { $0.id == id } }
    public func state(_ id: UUID) -> State { states[id] ?? .disconnected }

    // MARK: - Profile (CRUD)

    /// Zapisuje profil i (opcjonalnie) sekrety do Keychain. Puste pole = bez zmiany; `nil` hasła przy `rememberPassword == false` = tylko na sesję.
    @discardableResult
    public func save(_ profile: ConnectionProfile, password: String? = nil, passphrase: String? = nil,
                     rememberPassword: Bool = true) throws -> ConnectionProfile {
        if let problem = profile.validationError() { throw NetworkError.invalidProfile(problem) }
        var p = profile
        if let password, !password.isEmpty {
            if rememberPassword {
                let ref = p.passwordRef ?? SecretRef(); try secrets.setSecret(password, for: ref); p.passwordRef = ref
            } else {
                if let ref = p.passwordRef { try? secrets.deleteSecret(for: ref); p.passwordRef = nil }
                let ref = sessionRefs[p.id] ?? SecretRef(); try sessionSecrets.setSecret(password, for: ref); sessionRefs[p.id] = ref
            }
        }
        if let passphrase, !passphrase.isEmpty {
            if rememberPassword {
                let ref = p.passphraseRef ?? SecretRef(); try secrets.setSecret(passphrase, for: ref); p.passphraseRef = ref
            } else {
                if let ref = p.passphraseRef { try? secrets.deleteSecret(for: ref); p.passphraseRef = nil }
                let ref = sessionPassphraseRefs[p.id] ?? SecretRef(); try sessionSecrets.setSecret(passphrase, for: ref); sessionPassphraseRefs[p.id] = ref
            }
        }
        if let idx = profiles.firstIndex(where: { $0.id == p.id }) { profiles[idx] = p } else { profiles.append(p) }
        profileStore.save(profiles)
        return p
    }

    /// Usuwa profil. Sekrety usuwane są tylko na prośbę i tylko te, których nie używa inny profil.
    public func remove(_ id: UUID, deleteSecrets: Bool) async {
        guard let p = profile(id) else { return }
        await disconnect(id)
        if deleteSecrets {
            for ref in ProfileStore.exclusiveSecretRefs(of: p, among: profiles) { try? secrets.deleteSecret(for: ref) }
        }
        profiles.removeAll { $0.id == id }
        states[id] = nil
        profileStore.save(profiles)
    }

    /// Sekrety, które zostałyby usunięte razem z profilem (do pytania w UI).
    public func exclusiveSecretCount(of id: UUID) -> Int {
        guard let p = profile(id) else { return 0 }
        return ProfileStore.exclusiveSecretRefs(of: p, among: profiles).count
    }

    // MARK: - Sesje

    /// Provider połączonej sesji; przy utraconej lub nieistniejącej sesji łączy ponownie (z pytaniem o hasło, jeśli trzeba).
    public func provider(for id: UUID) async throws -> any FileProvider {
        if let p = providers[id], state(id) == .connected { return p }
        return try await connect(id)
    }

    @discardableResult
    public func connect(_ id: UUID) async throws -> any FileProvider {
        if let t = connecting[id] { return try await t.value }
        guard let profile = profile(id) else { throw NetworkError.invalidProfile("profil nie istnieje.") }
        if let problem = profile.validationError() { throw NetworkError.invalidProfile(problem) }
        states[id] = .connecting
        let task = Task { @MainActor [weak self] () throws -> any FileProvider in
            guard let self else { throw NetworkError.cancelled }
            let creds = try await self.resolveCredentials(profile)
            let provider = try self.makeProvider(profile, creds)
            try await provider.connect()
            return provider
        }
        connecting[id] = task
        defer { connecting[id] = nil }
        do {
            let provider = try await task.value
            providers[id] = provider
            states[id] = .connected
            return provider
        } catch {
            states[id] = .failed(message(error, profile: profile))
            throw error
        }
    }

    public func disconnect(_ id: UUID) async {
        connecting[id]?.cancel()
        if let p = providers.removeValue(forKey: id) { await p.disconnect() }
        // Hasła „tylko na sesję” znikają przy świadomym rozłączeniu.
        if let ref = sessionRefs[id] { try? sessionSecrets.deleteSecret(for: ref) }
        if let ref = sessionPassphraseRefs[id] { try? sessionSecrets.deleteSecret(for: ref) }
        states[id] = .disconnected
    }

    /// Zgłoszenie błędu z operacji: utrata sesji oznacza ją jako rozłączoną, więc kolejne użycie połączy ponownie.
    public func noteFailure(_ id: UUID, _ error: Error) {
        guard let n = error as? NetworkError else { return }
        switch n {
        case .connectionLost, .timeout:
            if let p = providers.removeValue(forKey: id) { Task { await p.disconnect() } }
            states[id] = .failed(message(error, profile: profile(id)))
        default: break
        }
    }

    /// Test połączenia na wersji roboczej profilu (np. z formularza): łączy, listuje katalog początkowy, rozłącza.
    /// Nic nie zapisuje (ani profilu, ani zaufania do klucza hosta bez jawnej akceptacji w tym samym oknie pytania).
    public func test(_ profile: ConnectionProfile, password: String?, passphrase: String?) async -> Result<String, NetworkError> {
        if let problem = profile.validationError() { return .failure(.invalidProfile(problem)) }
        do {
            var creds = ConnectionCredentials(password: password?.nilIfEmpty, passphrase: passphrase?.nilIfEmpty)
            if creds.password == nil, profile.auth == .password, let ref = profile.passwordRef { creds.password = try secrets.secret(for: ref) }
            if creds.passphrase == nil, profile.auth == .privateKey, let ref = profile.passphraseRef { creds.passphrase = try secrets.secret(for: ref) }
            let provider = try makeProvider(profile, creds)
            try await provider.connect()
            defer { Task { await provider.disconnect() } }
            let start = (try? await provider.initialPath()) ?? .root
            let count = try await provider.list(start).count
            return .success("Połączono. Katalog „\(start.string)”: \(count) elementów.")
        } catch {
            return .failure(Self.networkError(error, secrets: [password, passphrase].compactMap { $0 }))
        }
    }

    // MARK: - Użycie w panelach

    /// Lokalizacja startowa po połączeniu (łączy, jeśli trzeba).
    public func initialLocation(for id: UUID) async throws -> RemoteLocation {
        let provider = try await self.provider(for: id)
        let start = try await provider.initialPath()
        return RemoteLocation(connectionID: id, path: start)
    }

    /// Listing katalogu zdalnego jako wpisy panelu. Utrata sesji oznacza ją jako rozłączoną (kolejne użycie połączy ponownie).
    public func listing(_ location: RemoteLocation) async throws -> [FileEntry] {
        let provider = try await self.provider(for: location.connectionID)
        do {
            return try await provider.list(location.path).compactMap { $0.fileEntry(in: location) }
        } catch {
            noteFailure(location.connectionID, error)
            throw Self.networkError(error, secrets: [])
        }
    }

    // MARK: - Wewnętrzne

    private func makeProvider(_ profile: ConnectionProfile, _ creds: ConnectionCredentials) throws -> any FileProvider {
        guard let factory = providerFactory else { throw NetworkError.unsupported("protokół \(profile.proto.rawValue) (moduł protokołów nie jest załadowany)") }
        let prompt = hostKeyPrompt
        let verifier = HostKeyVerifier(store: trustedHostsStore) { info in
            guard let prompt else { return false }
            return await prompt(info)
        }
        return try factory(profile, ProviderContext(credentials: creds, hostKeyVerifier: verifier))
    }

    private func resolveCredentials(_ profile: ConnectionProfile) async throws -> ConnectionCredentials {
        var creds = ConnectionCredentials()
        switch profile.auth {
        case .anonymous: break
        case .password:
            creds.password = try await secret(profile, saved: profile.passwordRef, session: sessionRefs[profile.id], kind: .password) { self.sessionRefs[profile.id] = $0 }
        case .privateKey:
            // Passphrase bywa pusta (klucz bez hasła) — wtedy pytamy tylko, gdy biblioteka zgłosi, że jest wymagana (provider ponawia przez `credentialPrompt` w UI).
            if profile.passphraseRef != nil || sessionPassphraseRefs[profile.id] != nil {
                creds.passphrase = try await secret(profile, saved: profile.passphraseRef, session: sessionPassphraseRefs[profile.id], kind: .passphrase) { self.sessionPassphraseRefs[profile.id] = $0 }
            }
        }
        return creds
    }

    private func secret(_ profile: ConnectionProfile, saved: SecretRef?, session: SecretRef?, kind: CredentialKind,
                        remember: (SecretRef) -> Void) async throws -> String? {
        if let saved, let v = try secrets.secret(for: saved) { return v }
        if let session, let v = try sessionSecrets.secret(for: session) { return v }
        guard let prompt = credentialPrompt, let value = await prompt(profile, kind) else { throw NetworkError.cancelled }
        let ref = SecretRef(); try sessionSecrets.setSecret(value, for: ref); remember(ref)
        return value
    }

    private func message(_ error: Error, profile: ConnectionProfile?) -> String {
        Self.networkError(error, secrets: []).localizedDescription
    }

    /// Normalizuje dowolny błąd do `NetworkError` z zamaskowanymi sekretami.
    public nonisolated static func networkError(_ error: Error, secrets: [String]) -> NetworkError {
        if let n = error as? NetworkError {
            switch n {
            case .connectionFailed(let r): return .connectionFailed(Redactor.redact(r, secrets: secrets))
            case .other(let r): return .other(Redactor.redact(r, secrets: secrets))
            case .invalidResponse(let r): return .invalidResponse(Redactor.redact(r, secrets: secrets))
            case .tlsCertificateInvalid(let r): return .tlsCertificateInvalid(Redactor.redact(r, secrets: secrets))
            default: return n
            }
        }
        if error is CancellationError { return .cancelled }
        return .other(Redactor.redact((error as NSError).localizedDescription, secrets: secrets))
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
