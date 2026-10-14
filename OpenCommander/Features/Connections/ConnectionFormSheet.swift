import SwiftUI
import AppKit
import OpenCommanderCore
import OpenCommanderRemote

/// Formularz nowego / edytowanego połączenia. Pola dostosowują się do protokołu. Sekrety nie trafiają do profilu —
/// `ConnectionManager.save` zapisuje je w Keychain (albo tylko w pamięci sesji, gdy odznaczono „Zapamiętaj”).
struct ConnectionFormSheet: View {
    let state: AppState
    let existing: ConnectionProfile?

    @Environment(\.dismiss) private var dismiss
    @State private var draft: ConnectionProfile
    @State private var password = ""
    @State private var passphrase = ""
    @State private var remember = true
    @State private var portText = ""
    @State private var testing = false
    @State private var testResult: (ok: Bool, text: String)?
    @State private var saveError: String?

    init(state: AppState, existing: ConnectionProfile?) {
        self.state = state
        self.existing = existing
        let p = existing ?? ConnectionProfile(name: "", proto: RemoteModule.supportedProtocols.first ?? .sftp, initialPath: "")
        _draft = State(initialValue: p)
        _portText = State(initialValue: String(p.port))
        _remember = State(initialValue: existing == nil || existing?.passwordRef != nil || existing?.passphraseRef != nil)
    }

    private var isWebDAV: Bool { draft.proto == .webdav }
    private var insecure: Bool { !draft.isEncrypted && (draft.proto == .ftp || draft.proto == .webdav) }
    private var hasSavedPassword: Bool { existing?.passwordRef != nil }
    private var hasSavedPassphrase: Bool { existing?.passphraseRef != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(existing == nil ? "Nowe połączenie" : "Edytuj połączenie").font(.headline).padding([.top, .horizontal], 20).padding(.bottom, 8)
            Form {
                TextField("Nazwa", text: $draft.name)
                Picker("Protokół", selection: protocolBinding) {
                    ForEach(RemoteModule.supportedProtocols) { Text($0.title).tag($0) }
                }
                if isWebDAV {
                    TextField("Adres (https://serwer/ścieżka)", text: Binding(get: { draft.baseURL ?? "" }, set: { draft.baseURL = $0 }))
                        .onChange(of: draft.baseURL) { _, _ in syncPort() }
                } else {
                    TextField("Serwer", text: $draft.host)
                    TextField("Port", text: $portText).onChange(of: portText) { _, v in if let n = Int(v) { draft.port = n } }
                }
                if draft.proto == .ftps {
                    Picker("Tryb TLS", selection: $draft.ftpsMode) {
                        Text("Jawny (AUTH TLS, port 21)").tag(FTPSMode.explicit)
                        Text("Niejawny (port 990)").tag(FTPSMode.implicit)
                    }
                    .onChange(of: draft.ftpsMode) { _, _ in syncPort() }
                }
                Picker("Logowanie", selection: $draft.auth) {
                    ForEach(allowedAuth, id: \.self) { Text($0.title).tag($0) }
                }
                if draft.auth != .anonymous {
                    TextField("Użytkownik", text: $draft.username)
                }
                if draft.auth == .password {
                    SecureField("Hasło", text: $password, prompt: Text(hasSavedPassword ? "zapisane w Keychain — zostaw puste, by nie zmieniać" : ""))
                }
                if draft.auth == .privateKey {
                    HStack {
                        TextField("Plik klucza prywatnego", text: Binding(get: { draft.keyFilePath ?? "" }, set: { draft.keyFilePath = $0 }))
                        Button("Wybierz…") { chooseKey() }
                    }
                    SecureField("Hasło do klucza", text: $passphrase,
                                prompt: Text(hasSavedPassphrase ? "zapisane — zostaw puste, by nie zmieniać" : "puste, jeśli klucz nie ma hasła"))
                    Text("Zapisywana jest tylko ścieżka do pliku. Obsługiwane klucze: Ed25519 i RSA w formacie OpenSSH.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if draft.auth != .anonymous && !isWebDAV || draft.auth == .password {
                    Toggle("Zapamiętaj hasło w Keychain", isOn: $remember)
                    if !remember { Text("Hasło będzie pamiętane tylko do rozłączenia lub zamknięcia aplikacji.").font(.caption).foregroundStyle(.secondary) }
                }
                if !isWebDAV {
                    TextField("Katalog początkowy", text: $draft.initialPath, prompt: Text("puste = katalog domowy"))
                }
                if draft.proto == .ftp || draft.proto == .webdav {
                    Toggle("Zezwalam na połączenie bez szyfrowania", isOn: $draft.allowInsecure)
                }
                Stepper("Limit czasu połączenia: \(draft.connectTimeoutSeconds) s", value: $draft.connectTimeoutSeconds, in: 5...120, step: 5)
            }
            .formStyle(.grouped)

            if insecure {
                Label(draft.proto == .ftp
                      ? "Zwykłe FTP przesyła hasło i pliki jawnym tekstem — każdy w sieci może je podejrzeć. Użyj FTPS lub SFTP, jeśli serwer je wspiera."
                      : "WebDAV przez HTTP przesyła hasło i pliki jawnym tekstem. Używaj tylko w zaufanej sieci lokalnej.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange).padding(.horizontal, 20).padding(.bottom, 6)
            }
            if let r = testResult {
                Label(r.text, systemImage: r.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .font(.callout).foregroundStyle(r.ok ? .green : .red).textSelection(.enabled)
                    .padding(.horizontal, 20).padding(.bottom, 6)
            }
            if let e = saveError { Text(e).font(.callout).foregroundStyle(.red).padding(.horizontal, 20).padding(.bottom, 6) }

            HStack {
                Button("Testuj połączenie") { runTest() }.disabled(testing)
                if testing { ProgressView().controlSize(.small) }
                Spacer()
                Button("Anuluj", role: .cancel) { state.sheet = .connections }.keyboardShortcut(.cancelAction)
                Button("Zapisz") { save() }.keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 520)
        .connectionPrompts(state, topLevel: false)
    }

    // MARK: Logika formularza

    private var allowedAuth: [AuthMode] {
        switch draft.proto {
        case .sftp: return [.password, .privateKey]
        case .ftp, .ftps, .webdav: return [.password, .anonymous]
        }
    }

    private var protocolBinding: Binding<ConnectionProtocol> {
        Binding(get: { draft.proto }, set: { new in
            draft.proto = new
            if !allowedAuth.contains(draft.auth) { draft.auth = .password }
            if new == .webdav, draft.baseURL == nil { draft.baseURL = "https://" }
            syncPort()
        })
    }

    private func syncPort() {
        draft.port = ConnectionProfile.defaultPort(draft.proto, ftpsMode: draft.ftpsMode, baseURL: draft.baseURL)
        portText = String(draft.port)
    }

    private func chooseKey() {
        let dialog = NSOpenPanel()
        dialog.canChooseFiles = true; dialog.canChooseDirectories = false; dialog.allowsMultipleSelection = false
        dialog.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh")
        dialog.prompt = "Wybierz"; dialog.message = "Wybierz plik klucza prywatnego (zapisana zostanie tylko jego ścieżka)"
        if dialog.runModal() == .OK, let url = dialog.url { draft.keyFilePath = url.path }
    }

    private func runTest() {
        testing = true; testResult = nil
        let profile = draft, pw = password, pp = passphrase
        Task {
            let result = await state.connections.test(profile, password: pw, passphrase: pp)
            testing = false
            switch result {
            case .success(let text): testResult = (true, text)
            case .failure(let e): testResult = (false, e.localizedDescription)
            }
        }
    }

    private func save() {
        saveError = nil
        do {
            try state.connections.save(draft, password: password, passphrase: passphrase, rememberPassword: remember)
            state.sheet = .connections
        } catch {
            saveError = ConnectionManager.networkError(error, secrets: [password, passphrase]).localizedDescription
        }
    }
}
