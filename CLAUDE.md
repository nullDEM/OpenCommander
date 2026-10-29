# CLAUDE.md — OpenCommander

A dual-pane file manager for macOS (Swift, SwiftUI + AppKit): local files plus SFTP, FTP, FTPS and WebDAV. **Stages 1–3 are done; stage 4 (SFTP/FTP/FTPS/WebDAV): code and tests done, the interface has not been checked by hand against real servers** (see ROADMAP.md). *(Polish original: [docs/pl/CLAUDE.md](docs/pl/CLAUDE.md). The app UI is in Polish.)*

## Commands
```bash
swift test --scratch-path /tmp/oc-spm     # Core (196) + Remote (87; SFTP/WebDAV/FTP/FTPS against local in-process servers)
xcodegen generate                          # after changing project.yml
xcodebuild -project OpenCommander.xcodeproj -scheme OpenCommander -destination 'platform=macOS' -derivedDataPath /tmp/oc-dd build
```
The repo may live in an iCloud folder (Documents): keep build artifacts outside it (`--scratch-path`, `-derivedDataPath`), otherwise codesign reports "detritus".

## Structure
- `Sources/OpenCommanderCore`: Models, FileSystem, Operations, Persistence, Network (all the logic; no network libraries)
- `Sources/OpenCommanderRemote`: SFTP (Citadel), WebDAV (URLSession), FTP/FTPS (system libcurl through `Sources/CCurl`)
- `Tests/OpenCommanderCoreTests`: tests on temporary directories (+ `FakeProvider`)
- `Tests/OpenCommanderRemoteTests`: tests against local servers (127.0.0.1) inside the test process
- `OpenCommander/`: App, Features/{Browser,Sidebar,Operations,Connections,...}
- `Tools/icon/`: icon sources (SVG + script); PNGs in `OpenCommander/Assets.xcassets/AppIcon.appiconset`
- `project.yml` → `OpenCommander.xcodeproj`

## Operation safety rules
- Never overwrite by default; conflict: skip / keep both / replace (replace = explicit decision, the old item goes to the Trash).
- Deleting in the UI = Trash. No permanent deletion except removing the source after a *successful* copy when moving between volumes, and cleaning up our own `.opencommander-tmp-*` files.
- Do not remove the source after a failed copy. Protect against copying a folder into itself or a descendant. Do not follow symbolic links.
- Do not promise undo or atomicity. Byte progress only where it is really measured (the `copyfile` callback); otherwise progress in items. Speed and time remaining are smoothed estimates, not promises. A copy can be cancelled in the middle of a file; the temporary copy is then removed and the source is untouched.
- Tests: temporary directories only; the Trash only through the `Trashing` fake. Do not run the app or tests against the owner's private files.
- Temporary files always go through `TempJournal`; clean up only files with the `.opencommander-tmp-` prefix, and restore `movedSource`, never delete it.
- Do not read file contents when listing; do not compute folder sizes or hashes without a user action.
- Ejecting only as an explicit user action, only volumes with `canEject`; never the system disk or a volume with an active operation in the queue. Eject tests only on your own disk image (`hdiutil -nobrowse`).

## Safely testing the app (IMPORTANT)
The owner usually runs the app themselves (from Xcode, under the debugger). **Never** use `pkill -x OpenCommander`, `defaults write/delete` on `org.opencommander.OpenCommander`, or look up a window by process name: you would touch their instance, settings and data (a window capture chosen by process name can grab someone else's screen).
Instead: build into a separate `-derivedDataPath`, make a **copy of the app with a changed `CFBundleIdentifier`** (for example `org.opencommander.OpenCommander.test`, re-sign with `codesign --force --deep --sign -`), set preferences only in that domain, run the binary directly, remember the PID and kill only that PID; pick the window to capture by PID. Keep demo data in a temporary directory.

## Network connections: rules (stage 4)
The network ban was **lifted by the owner** for: SFTP, FTP, FTPS (explicit / implicit), WebDAV (HTTPS; HTTP only as an explicitly chosen, warned variant). Other protocols and proprietary clouds still need a scope change.
- **Secrets:** passwords and passphrases only in the Keychain (`SecretStore`) or in session memory; never in UserDefaults / JSON / SQLite / bookmarks, code, logs, tests (except the fictional passwords of test servers), the repository or error messages (`Redactor`). A private key is stored as a file path only.
- **Do not connect to real servers** of the owner or public ones (tests only against in-process servers on 127.0.0.1). Do not use real passwords or keys in tests. A connection to a real server needs separate, explicit consent from the owner; pass credentials through stdin or environment variables and never write them to files.
- **Do not implement SSH, TLS or cryptography yourself.** TLS: always verify the certificate and host name; never "accept all" (trust may only be *narrowed*, for example `CAINFO` in tests). Plain FTP and HTTP only after `allowInsecure`; FTPS never silently falls back to FTP.
- **SSH:** unknown host key → ask with the fingerprint, save only after acceptance; changed key → block without asking.
- **Transfers:** copying local↔remote only (no moves, no server→server); the local source is never deleted; uploads through a temporary name `.opencommander-tmp-*` plus a size check; downloads through a temporary file registered in `TempJournal`; server names are untrusted (path traversal, CR/LF); remote symlinks are not followed; do not claim resume or atomicity; after a lost connection do not automatically retry destructive operations (a retry is manual, from the beginning).
- **UI:** remote delete is not the Trash: a separate confirmation with the server, path and item count, and a note that it is irreversible. Do not show a function a given server does not support.
- **Testing the app with connections:** only in a copy with a different `CFBundleIdentifier` (as above); test server: `OC_SERVE_SECONDS=300 swift test --filter SFTPIntegrationTests/testServeForManualUI` (127.0.0.1:2222). Screenshots and clicks only in the window of your own copy (by PID).

## Scope
No commits or pushes without consent. When adding a dependency: pinned version, license checked and described in the README.
