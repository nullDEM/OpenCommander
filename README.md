# OpenCommander

A native, dual-pane file manager for macOS. Local folders and **SFTP**, **FTP**, **FTPS** and
**WebDAV** servers side by side in the same two panels. Written in Swift with SwiftUI and AppKit.
No Electron, no account, no telemetry: the app only connects to servers you add yourself.

<p align="center">
  <img src="docs/screenshots/dark.png" alt="OpenCommander, dark theme, two panels with tabs" width="900"><br>
  <img src="docs/screenshots/light.png" alt="OpenCommander, light theme" width="900">
</p>

> The user interface is currently in Polish. A Polish version of this README is in
> [docs/README.pl.md](docs/README.pl.md).

## Status
Early version **0.1**. The file logic is covered by automated tests (SwiftPM, temporary
directories only; network protocols are tested against local servers started inside the test
process), but **the interface is checked by hand**: the checklist is in
[MANUAL_TESTS.md](MANUAL_TESTS.md). Expect bugs and report them through Issues.

The app is **not notarized** or signed with a developer certificate, so build it from source
(below). It runs without the App Sandbox and without Full Disk Access (rationale in
[ARCHITECTURE.md](ARCHITECTURE.md)).

## Features

| Feature | How |
|---|---|
| Two independent panels | Tabs in each panel (⌘T, up to 10), workspaces that save and restore both panels' tabs |
| Browsing | Multi-select table with sorting, breadcrumbs, history, draggable divider, configurable columns, automatic refresh of the open folder |
| Sidebar | Favorites, places, volumes (with an **eject** button for USB drives, cards and disk images, never the system disk), recent locations, **connections** |
| Search | ⌘F by name in the folder and subfolders (case and diacritics insensitive), Quick Look on Space, info panel (⌘I) with folder size computed on demand only |
| Copy, move, rename, trash | Operation queue with live progress (bytes, speed, estimated time), cancelling even in the middle of a large file |
| Conflicts | Skip / keep both / replace; nothing is overwritten by default and replaced local items go to the Trash |
| Clipboard and drag and drop | ⌘C / ⌘V (also with Finder), dragging between panels and from Finder |
| Batch rename | ⇧⌘R with a before → after preview and collision blocking |
| Compare folders | ⇧⌘K by name, size and date, with copying of the differences |
| Duplicate finder | By content (SHA-256), only on demand; removal goes to the Trash and always keeps one copy |
| Network connections | SFTP, FTP, FTPS (explicit and implicit TLS) and WebDAV; each panel can show a local folder or a server location |
| Secrets | Passwords and key passphrases only in the Keychain (or in memory for the session), never in settings files or logs |

Full list of shortcuts: **Help → Keyboard Shortcuts** (⇧⌘/) and the table below.

## Network connections
Use the **Connections** section in the sidebar (⌥⌘K opens the connection manager). Copying between a
local panel and a server panel (F5, dragging, ⌘V) is an upload or a download through the normal
operation queue.

**Adding a connection:** sidebar → **＋** next to "Connections" (or the *Połączenia → Nowe połączenie…* menu)
→ pick a protocol, fill in the fields, **Test connection**, **Save**. Clicking a connection in the
sidebar connects and opens its start folder in the active panel.

| | SFTP | FTP | FTPS (explicit / implicit) | WebDAV |
|---|---|---|---|---|
| Encryption | SSH | **none** (needs explicit consent in the profile) | TLS 1.2, certificate and host name verified | HTTPS (HTTP only after explicit consent, with a warning) |
| Login | password, key (Ed25519 / RSA, also with a passphrase) | password, anonymous | password, anonymous | password (Basic / Digest), anonymous |
| List, download, upload | ✅ | ✅ (MLSD, LIST as a heuristic fallback) | ✅ | ✅ |
| New folder, rename, delete | ✅ | ✅ | ✅ | ✅ |
| Resuming interrupted transfers | ❌ | ❌ | ❌ | ❌ |
| Moving between local and remote | ❌ (copy only) | ❌ | ❌ | ❌ |
| Server to server copy | ❌ | ❌ | ❌ | ❌ |
| Server verification | key fingerprint (asked on first connect, blocked when it changes) | n/a | TLS certificate | TLS certificate |

What this means in practice:
- **Deleting on a server is not the Trash.** The app asks separately and shows the server, folder and
  number of items; it may be irreversible.
- **Nothing is overwritten by default.** Conflicts: skip / keep both / replace (replacing on a server
  overwrites the file without a Trash, and the dialog says so). Replacing a *folder* on a server is blocked.
- Uploads go through a temporary name `.opencommander-tmp-…` and a rename after the size check, so an
  interrupted or cancelled transfer never leaves a file that looks complete. **Retry** restarts the failed
  item from the beginning; nothing is retried automatically.
- The local source is never deleted after an upload. Symbolic links on a server are neither followed nor copied.
- File names coming from a server are untrusted: names with `/`, `..` or control characters are rejected
  (protection against path traversal and FTP command injection).

### Secrets and trust
- **Passwords and key passphrases go only to the Keychain** (generic password, `ThisDeviceOnly`, no iCloud
  sync). The profile store (UserDefaults, JSON) holds configuration and an anonymous secret identifier, never a
  password, passphrase or key contents (for a private key only the file path is stored).
- Untick "remember password in Keychain" and the password lives only in memory until you disconnect or quit.
- When you delete a profile you choose whether to delete its secrets too; a secret shared with another profile
  is never deleted.
- Errors and messages are redacted (passwords, tokens, Authorization/Cookie headers, URLs with credentials,
  PEM key blocks). The app does not write logs to disk.
- **SFTP:** on first connect you see the host, port, key type and SHA256 fingerprint; trust is saved only after
  you accept. **A changed key blocks the connection without asking.** The trusted list (view / remove) is under
  *Połączenia → Zaufane serwery SSH*. It is the app's own file, **not** full `~/.ssh/known_hosts` support
  (no hashed host names, patterns, certificates or `@revoked`).
- **FTPS:** there is no "accept everything": an untrusted or mismatching certificate ends the connection, and a
  server without TLS never makes the app silently fall back to plain FTP (the password is not sent). **WebDAV:**
  no redirects to another host, no HTTPS to HTTP downgrade, credentials only to the host of the base address.

### Limitations
- Transfers are not resumed. SFTP sends data sequentially in 32 KiB chunks, so on high-latency links it is slower
  than the OpenSSH client.
- SFTP: the Citadel library reads Ed25519 and RSA keys in OpenSSH format (no ECDSA, no legacy PEM) and
  supports only Ed25519 / ECDSA **host** keys, so servers that offer only RSA/DSA host keys cannot be reached over
  SFTP (use FTPS there). It builds on a fork of `swift-nio-ssh` (see [ARCHITECTURE.md](ARCHITECTURE.md)).
- FTP: without MLSD the times from `LIST` are approximate and unusual list formats are skipped and counted, not
  guessed. One connection, operations run one at a time. File names are UTF-8. FTPS is capped at TLS 1.2
  because many servers (for example ProFTPD) require TLS session reuse on the data channel.
- WebDAV: no locking (LOCK) and no PROPPATCH; with Digest authentication an upload body may be sent twice.
  Files in a remote panel are not opened directly: copy them to disk first.
- Remote items have no Quick Look, no "Reveal in Finder" and no favorites; batch rename, folder comparison and
  duplicates work on local folders only.
- A remote listing refreshes manually (⌘R) and after the app's own operations; there is no change watcher.
- macOS may ask for local network access when you connect to devices on your LAN.
- If a server drops the connection, the next action reconnects (asking for the password when it is not saved);
  interrupted operations have to be retried by hand.

### Testing with servers (safely)
The automated tests connect **only to servers started inside the test process on 127.0.0.1** (temporary
directories, certificates generated for the test), never to public servers or yours. `swift test` covers SFTP
(password, unknown / changed host key, dropped connection, cancelling, Unicode), WebDAV (207 responses,
namespaces, path prefix, redirects, authentication, invalid certificate), FTP (MLSD / LIST, passive mode,
dropped connection) and explicit / implicit FTPS (certificate and host verification, no downgrade). The explicit
FTPS tests use `python3` and `openssl` from the system and are skipped when they are missing.

To check the interface by hand you can start a local test SFTP server:
`OC_SERVE_SECONDS=300 swift test --filter SFTPIntegrationTests/testServeForManualUI` (listens on
`127.0.0.1:2222`, user `ola`, password from `TestSFTPServer`), and add an SFTP profile for that address in **a copy
of the app with a different bundle identifier** (see [CLAUDE.md](CLAUDE.md)).

### Libraries and licenses
| Component | Used for | License |
|---|---|---|
| [Citadel](https://github.com/orlandos-nl/Citadel) 0.12.1 | SFTP / SSH | MIT |
| [swift-nio-ssh](https://github.com/Wellz26/swift-nio-ssh) 0.3.7 (fork used by Citadel) | SSH | Apache-2.0 |
| swift-nio, swift-log, swift-crypto, swift-asn1, swift-atomics, swift-collections, swift-system (Apple) | transitive dependencies | Apache-2.0 |
| [BigInt](https://github.com/attaswift/BigInt) 5.7.0 | transitive dependency | MIT |
| libcurl (system, `libcurl.4.dylib`) | FTP / FTPS | curl license; a macOS system library, not bundled with the app |
| `URLSession`, `XMLParser`, Keychain, Network.framework | WebDAV, XML, secrets | part of macOS |

Versions are pinned in `Package.swift` (Citadel with `exact`) and `Package.resolved`. SSH, TLS and
cryptography are not implemented in this project.

## Data safety
- Nothing is overwritten by default; deleting a local item from the UI always means the Trash (on a server there
  is a separate, explicit confirmation, see above).
- When moving between volumes the source is removed only after a successful copy; copying a folder into itself is
  blocked; symbolic links are copied as links.
- Temporary files are recorded in a journal: after an interrupted session unfinished copies are cleaned up and
  items interrupted in the middle of a move are **restored**, not deleted.
- Folder sizes and content hashes are computed only after a user action; listing never reads file contents.

Details and rules for contributors: [CLAUDE.md](CLAUDE.md).

## Requirements and building
macOS 14.4 or later (minimum window width 900 pt), Xcode 15 or later (developed on Xcode 27 / Swift 6.4).

```bash
# logic tests (SwiftPM)
swift test --scratch-path /tmp/oc-spm

# the app
xcodebuild -project OpenCommander.xcodeproj -scheme OpenCommander \
  -destination 'platform=macOS' -derivedDataPath /tmp/oc-dd build
open /tmp/oc-dd/Build/Products/Debug/OpenCommander.app
```
The Xcode project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen);
`OpenCommander.xcodeproj` is in the repository, so XcodeGen is not needed for an ordinary build.
If the repository lives in an iCloud-synced folder (for example Documents), code signing may complain about
"detritus": build with `-derivedDataPath` outside that folder, as above.

## Keyboard shortcuts
| Shortcut | Action |
|---|---|
| Tab, ⌘` | switch panel |
| Enter, ⌘↓ | open |
| ⌘↑ / ⌘[ / ⌘] | parent folder / back / forward |
| ⌘R | refresh |
| ⇧⌘N / ⇧⌘O | new folder / choose folder |
| F2 | rename |
| F5 / F6 | copy / move to the other panel |
| ⌘C / ⌘V (also ⌥C / ⌥V) | copy / paste files |
| ⌥⌘C | copy path |
| ⌘⌫ | move to Trash (with confirmation); on a server, delete after a separate confirmation |
| ⌘E | eject the volume of the active panel |
| ⌥⌘R | reveal in Finder |
| ⌘F | search in the folder and subfolders (Esc closes) |
| Space | Quick Look |
| ⌘I | info panel |
| ⇧⌘. | hidden files |
| ⌘D | add / remove the folder from favorites |
| ⌘T / ⌘W | new tab / close tab (the last tab of a panel closes the window) |
| ⇧⌘] / ⇧⌘[ | next / previous tab |
| ⌥⌘S | save workspace |
| ⌥⌘K | connection manager |
| ⇧⌘R | batch rename |
| ⇧⌘K | compare folders |
| ⇧⌘/ | shortcut list |

F keys need Fn or the "Use F1, F2, etc. keys as standard function keys" option; every action is also in the menus.

## Known limitations
- In narrow panels (for example with the info panel open) the "Kind" and "Modified" columns may be clipped:
  change the column visibility with a right click on the table header, or widen the panel by dragging the divider.
- Automatic refresh sees changes directly in the open folder, not in subfolders or file contents.
- Batch rename rejects swaps and chains of names (a→b, b→a) instead of handling them.
- The plan and what is still missing: [ROADMAP.md](ROADMAP.md).

## Contributing
See [CONTRIBUTING.md](CONTRIBUTING.md). File logic must have tests on temporary directories; network
tests only against local servers inside the test process.

## License and credits
MIT, see [LICENSE](LICENSE). App icon: [Tools/icon](Tools/icon/README.md) (designed with the
[logo-design](https://github.com/kaankiziltug/logo-design-skill) skill, MIT).
