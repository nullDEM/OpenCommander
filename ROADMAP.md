# Roadmap

*(Polish original: [docs/pl/ROADMAP.md](docs/pl/ROADMAP.md).)*

Scope: local files plus **SFTP, FTP, FTPS and WebDAV** (stage 4). The earlier network ban was deliberately lifted by the owner; proprietary clouds (Dropbox, the iCloud Drive API, S3 and so on) are still out of scope.

## Stage 1: done (0.1)
Two panels, table, sorting, selection, navigation, breadcrumbs, hidden files, opening, new folder, rename, copy / move / Trash, conflicts, queue, settings. See the README.

## Stage 2: in progress (batches A, B and C done; file clipboard done)
- [x] tabs in panels (`PanelTabs`; each tab is a `PanelState`)
- [x] favorites and recent locations
- [x] Quick Look (Space)
- [x] context menu (including "Open with", reveal in Finder, copy path)
- [x] drag and drop between panels and the file clipboard (⌘C / ⌘V)
- [x] current folder filter
- [x] info panel, folder size on demand
- [x] workspaces (`Workspace`)
- [ ] typing a path, icon view
- [x] draggable divider between panels (own Layout, no HSplitView)
- [x] automatic folder refresh (DispatchSource, not full FSEvents)

## Stage 3
- [x] recursive search (cancellable)
- [x] batch rename with a preview and collision detection (swaps and chains are rejected, not handled)
- [x] folder comparison, duplicate finder (hashing only on demand)

## Stage 4: network connections (code and tests done; the interface verified only by compilation and logic tests)
- [x] common layer: `RemoteLocation` (`ocremote://`), `ConnectionProfile` without secrets, `FileProvider`, `NetworkError`, Keychain (`SecretStore`), trusted SSH hosts
- [x] SFTP (Citadel): password and key, list, download, upload, mkdir, rename, delete, host key trust on first use
- [x] WebDAV (URLSession): HTTPS, HTTP with a warning, PROPFIND / GET / PUT / MKCOL / MOVE / DELETE
- [x] FTP and FTPS explicit / implicit (system libcurl): passive mode, MLSD with a LIST fallback
- [x] queue: uploading / downloading folders, cancelling, manual "Retry from the beginning", conflicts, remote delete with confirmation
- [x] interface: "Connections" sidebar section, manager, per-protocol form, connection test, password and host key prompts, trusted hosts view
- [ ] manual walk-through of the interface against a real server (list in [MANUAL_TESTS.md](MANUAL_TESTS.md))
- [ ] resumable transfers, parallel transfers, opening remote files (download to a temporary file and open), change watcher
- [ ] ECDSA keys / PEM format and RSA host keys in SFTP (needs another SSH library), `known_hosts` import

## Later
- safe synchronization of local folders, archives, operation history
- consider App Sandbox + security-scoped bookmarks (Mac App Store distribution)
- localization (en)
