# CLAUDE.md — OpenCommander

Lokalny, dwupanelowy menedżer plików na macOS (Swift, SwiftUI + AppKit). **Aktualny etap: 1 ukończony, następny: etap 2** (zob. ROADMAP.md).

## Polecenia
```bash
swift test --scratch-path /tmp/oc-spm     # testy Core (108)
xcodegen generate                          # po zmianie project.yml
xcodebuild -project OpenCommander.xcodeproj -scheme OpenCommander -destination 'platform=macOS' -derivedDataPath /tmp/oc-dd build
```
Repo bywa w folderze iCloud (Documents): artefakty buildu trzymaj poza nim (`--scratch-path`, `-derivedDataPath`), inaczej codesign zgłasza „detritus”.

## Struktura
- `Sources/OpenCommanderCore` — Models, FileSystem, Operations, Persistence (cała logika)
- `Tests/OpenCommanderCoreTests` — testy na katalogach tymczasowych
- `OpenCommander/` — App, Features/{Browser,Sidebar,Operations}
- `Tools/icon/` — źródła ikony (SVG + skrypt); PNG w `OpenCommander/Assets.xcassets/AppIcon.appiconset`
- `project.yml` → `OpenCommander.xcodeproj`

## Zasady bezpieczeństwa operacji
- Nigdy nie nadpisuj domyślnie; konflikt: pomiń / zachowaj obie / zastąp (zastąp = jawna decyzja, stary element do Kosza).
- Usuwanie w UI = Kosz. Żadnego trwałego kasowania poza usunięciem źródła po *udanej* kopii przy przenoszeniu między woluminami i sprzątaniem własnych plików `.opencommander-tmp-*`.
- Nie usuwaj źródła po nieudanym kopiowaniu. Chroń przed kopiowaniem folderu do siebie/potomka. Nie rozwijaj dowiązań symbolicznych.
- Nie obiecuj cofania operacji ani atomowości. Postęp bajtowy tylko tam, gdzie jest naprawdę mierzony (callback `copyfile`); inaczej postęp w elementach. Prędkość i czas do końca to wygładzone szacunki, nie obietnice. Kopiowanie można przerwać w środku pliku — kopia tymczasowa jest wtedy usuwana, źródło nietknięte.
- Testy: wyłącznie katalogi tymczasowe; Kosz tylko przez atrapę `Trashing`. Nie uruchamiaj aplikacji ani testów na prywatnych plikach właściciela.
- Pliki tymczasowe zawsze przez `TempJournal`; sprzątanie wyłącznie plików z prefiksem `.opencommander-tmp-`, a `movedSource` przywracaj, nie kasuj.
- Nie czytaj zawartości plików przy listowaniu; nie licz rozmiarów folderów/hashy bez akcji użytkownika.

- Wysuwanie tylko jawnym działaniem użytkownika, tylko woluminów z `canEject`; nigdy dysku systemowego ani woluminu z aktywną operacją w kolejce. Testy wysuwania wyłącznie na własnym obrazie dysku (`hdiutil -nobrowse`).

## Bezpieczne testowanie aplikacji (WAŻNE)
Właściciel zwykle uruchamia aplikację sam (z Xcode, pod debuggerem). **Nigdy** nie używaj `pkill -x OpenCommander`, `defaults write/delete` na `org.opencommander.OpenCommander` ani wyszukiwania okna po nazwie procesu — dotykasz jego instancji, ustawień i danych (zrzut okna wybrany po nazwie procesu może przechwycić cudzy ekran).
Zamiast tego: zbuduj do osobnego `-derivedDataPath`, zrób **kopię aplikacji ze zmienionym `CFBundleIdentifier`** (np. `org.opencommander.OpenCommander.test`, re-sign `codesign --force --deep --sign -`), ustawiaj ustawienia tylko w tej domenie, uruchamiaj binarkę bezpośrednio, zapamiętaj PID i zabijaj wyłącznie ten PID; okno do zrzutu wybieraj po PID. Dane demo trzymaj w katalogu tymczasowym.

## Zakres
**Zakaz dodawania funkcji sieciowych** (FTP/SFTP/chmury/połączenia) bez jawnej zmiany zakresu przez właściciela. Bez commitów/pushy bez zgody. Bez sandboxa (decyzja w ARCHITECTURE.md); bez wymagania Full Disk Access.
