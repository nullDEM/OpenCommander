# Manual tests (system dependent)

*(Polish original: [docs/pl/MANUAL_TESTS.md](docs/pl/MANUAL_TESTS.md). Menu and button names are in the Polish UI; English glosses are in parentheses.)*

Run these **only on copies / test folders**, never on important data. The automated tests (`swift test`) cover the logic; this list covers what cannot be checked without a window and the system.

## Preparation
Create a folder `~/OC-test` with subfolders `A` and `B`. Put a few files in `A` (including `raport.xlsx`, a ~1 GB file, a file with an emoji in its name, and a symbolic link made with `ln -s`), and in `B` a file `raport.xlsx` with different content.

## Interface and keyboard
- [ ] Both panels show a folder; clicking a panel makes it active (a bar at the top, the other panel's header dimmed).
- [ ] **Tab** in the table switches the panel; **⌘`** too; Tab in a sheet's text field does **not** switch panels.
- [ ] Arrows, Shift/⌘-click: multi-selection. **Enter** opens a folder / file exactly once.
- [ ] Clicking a column header sorts; the direction arrow is right; the sort order survives an app restart.
- [ ] **⌘↑**, **⌘[**, **⌘]**, **⌘R**, **⇧⌘N**, **⇧⌘.**, **⇧⌘O**, **F2**, **F5**, **F6**, **⌘⌫** work; menu items are greyed out when the action is unavailable (for example with no selection).
- [ ] **Esc** closes sheets (new folder, rename); in a conflict it means "Anuluj operację" (cancel the operation).
- [ ] Focus is visible; check the light and dark theme, a small window (minimum 900 pt) and a large one.
- [ ] VoiceOver reads file names, "symbolic link", the active panel, progress.

## Stage 2A
- [ ] **⌘F** shows the filter bar, typing "zolc" finds "Żółć…"; **Esc** closes and clears it; changing folder clears the filter; copying / Trash acts only on the items visible after the filter.
- [ ] **Space** on a selected file opens Quick Look (arrows switch, Space closes).
- [ ] Right-click on an item outside the selection selects it; menu: Open, **Open with** (list of apps), Reveal in Finder, Copy path, Info, favorites, copy / move, rename, Trash. Right-click on empty space: new folder, refresh, hidden files.
- [ ] **⌘I** opens the info panel (also **when the app starts with the panel open, which used to be a crash source**); it shows type, dates, permissions, the symlink target; "Oblicz rozmiar" (Compute size) for a folder only counts after the click and can be cancelled.
- [ ] **⌘D** adds / removes a folder from favorites; favorites and "Ostatnie" (Recent) in the sidebar survive a restart; a removed favorite folder is greyed out.

## Stage 2B: tabs and workspaces
- [ ] **⌘T** (or the ⊞ button in the header) adds a tab with the same location; the tab bar appears with ≥ 2 tabs; clicking switches; × and **⌘W** close; **⌘W on the last tab of a panel closes the window**; also check that the File menu has no second "Close".
- [ ] Each tab has its own history (back / forward), selection, sort order and filter; after returning to a tab everything is in place.
- [ ] "Open in a new tab" from a folder's context menu; **⇧⌘]** / **⇧⌘[** switch tabs cyclically; the limit of 10 tabs shows a message.
- [ ] Tabs and the active tab survive an app restart; a tab with a deleted folder opens the nearest existing one.
- [ ] **Workspaces:** ⌥⌘S saves (an empty name and **a repeated name are rejected**); choosing from the "Przestrzenie" menu or the sidebar restores both panels' tabs; "Usuń przestrzeń" (delete workspace) works; workspaces survive a restart.

## Stage 2C: dragging and refreshing
- [ ] Dragging a file / selection from one panel to the other: same volume → move, with ⌥ → copy; the operation appears in the queue.
- [ ] Dragging a multi-item selection moves all of them; dragging an unselected row moves only that row.
- [ ] Dropping onto the same folder does nothing; a name conflict shows the dialog.
- [ ] Dragging from Finder into a panel works (usually a copy / move depending on the volume).
- [ ] A file added / removed from Finder or Terminal appears / disappears in the panel within about 0.5 s, without losing the selection.
- [ ] **⌘C / ⌘V** (and ⌥C / ⌥V) in a panel copy the selected files and folders to the clipboard and paste them into the active panel's folder; pasting to and from Finder works; in the filter field ⌘C / ⌘V act on text.
- [ ] Clicking an external drive in the sidebar always opens it in the right panel (and activates it).
- [ ] **⌘F** typing part of a name finds files in subfolders (with the relative path next to the name); Enter / double-click on a result opens the file, and a folder enters it; the button next to the field switches to a plain filter of the current list; changing folder clears the search.

## Stage 3: tools and layout
- [ ] **⇧⌘R** on selected files: the preview updates live; collisions are red and block the button; after running, the new names are selected.
- [ ] **⇧⌘K** with two different folders shows the differences; "Kopiuj zaznaczone →/←" (copy selected) puts them in the queue; identical folders → "Foldery są takie same" (the folders are the same).
- [ ] **Duplicates:** "Szukaj duplikatów" (find duplicates) only works after the click; "Przerwij" (stop) works; selecting all copies in a group is rejected; deleting goes to the Trash.
- [ ] **Divider:** dragging changes the panel widths, you cannot go below about 250 pt, a double-click restores equal widths; start with the info panel open without a crash.
- [ ] Right-click on the table header lets you hide columns (for example "Rodzaj" / Kind): check that the setting works and is remembered.
- [ ] Light and dark themes look right.
- [ ] **Pomoc → Skróty klawiszowe** (Help → Keyboard Shortcuts, ⇧⌘/) opens the list window; check that the listed shortcuts really work.

## Operations
- [ ] New folder (including a name with `/`, empty, existing → a readable error, no change on disk).
- [ ] Rename; change **only the letter case** (`raport.xlsx` → `Raport.xlsx`).
- [ ] Copy `A→B` with a conflict: **Pomiń** (skip), **Zachowaj obie** (keep both, `… kopia.xlsx`), **Zastąp** (replace; the old one lands in the Trash, check the Trash and "Put Back").
- [ ] "Zastosuj do wszystkich" (apply to all) asks only once. **Esc** / "Anuluj operację" stops everything.
- [ ] Copying within the same folder (both panels on `A`) creates "… kopia"; Move is disabled.
- [ ] Move to the Trash with a confirmation; the item comes back with "Put Back". The app does not empty the Trash.
- [ ] A large file **to another volume** (an external drive / disk image): the byte bar, speed, time and ETA grow smoothly; **Cancel in the middle** → no destination or temporary file, the source untouched.
- [ ] Same volume (APFS): copying is instant (a clone); the bar jumps to the end, which is expected.

## Failures and environment
- [ ] **Force Quit the app in the middle of copying a large file** → after restart a cleanup message; no `.opencommander-tmp-*` is left in the destination folder.
- [ ] Unplug a volume during copying → a readable error, the source untouched.
- [ ] A read-only volume / no permissions (`chmod 000`) → a permissions error, no leftovers.
- [ ] A full disk (a small disk image) → a "Brak miejsca" (no space) message, the source untouched, no temporary file.
- [ ] A folder into its own descendant → refused with a message.
- [ ] Volumes in the sidebar: plug / unplug → the list refreshes; breadcrumbs for `/Volumes/X` start with "X".
- [ ] **Ejecting:** the ⏏ button in the sidebar next to a USB drive / disk image ejects it; Macintosh HD has no button. After ejecting, panels that showed it return to the home folder. ⌘E ejects the active panel's volume.
- [ ] Ejecting a busy volume (a file open in another app) → a message with the reason, the volume stays.
- [ ] Ejecting a volume with a queued copy in progress → refused with a message (cancel the operation first).
- [ ] Desktop / Documents: the system asks for consent (TCC); the app does not require Full Disk Access.

## Stage 4: network connections (on your own test server or the local server from the tests)
Use a server you do not use for anything important (for example `OC_SERVE_SECONDS=600 swift test --filter SFTPIntegrationTests/testServeForManualUI` → `127.0.0.1:2222`, user `ola`). Run the app in a copy with a different bundle identifier.
- [ ] Sidebar → "Połączenia" (Connections) → **＋**: the form shows protocol-dependent fields; FTP and WebDAV over HTTP show a warning and need consent; **Testuj połączenie** (test connection) returns a readable result; a wrong address / port / password gives the right message (DNS, refused, authentication) without the password in the text.
- [ ] The first SFTP connection shows the server, port, key type and fingerprint; "Nie ufaj" (don't trust) aborts and saves nothing; "Zaufaj i połącz" (trust and connect) saves (visible in *Połączenia → Zaufane serwery SSH*); after removing the trust the question comes back.
- [ ] Password: with "Zapamiętaj w Keychain" ticked the next connection does not ask; unticked, it asks after a disconnect; editing a profile with an empty password field does not change the saved password.
- [ ] Clicking a connection opens the start folder in the active panel; breadcrumbs start with the connection name; "up" stops at the server root; back / forward work across local and remote.
- [ ] Both panels on different servers: F5 server→server refuses with a message; local→remote is an upload, remote→local a download; **F6 (move) is disabled** when either panel is remote.
- [ ] Uploading / downloading a folder with files whose names contain spaces, `#`, `%`, Polish characters and emoji; byte progress, speed; **cancelling** in the middle of a large file leaves neither a file nor `.opencommander-tmp-*` on the server.
- [ ] A name conflict during upload: skip / keep both / replace; the "replace" dialog says the server has no Trash; replacing a folder is rejected.
- [ ] **⌘⌫** in a remote panel: a question with the server name, folder and number of items and a note that it is irreversible; after confirming, the items disappear from the server and do not go to the Trash.
- [ ] Disconnecting the server (switching it off, Wi-Fi) during a transfer: the operation ends with an error and a "Ponów nieudane od początku" (retry failed from the beginning) button; after the server is back, retrying works and the next action reconnects.
- [ ] The context menu of a remote item has no "Pokaż w Finderze", Quick Look or favorites; Space does nothing; double-clicking a file explains that it has to be copied.
- [ ] Deleting a profile: a question whether to delete the secrets from the Keychain; after "only the profile" the password stays in the Keychain (Keychain Access → items of the service `org.opencommander.OpenCommander.connections`).
