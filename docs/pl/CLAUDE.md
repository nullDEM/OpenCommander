# CLAUDE.md — OpenCommander

Lokalny, dwupanelowy menedżer plików na macOS (Swift, SwiftUI + AppKit). **Etapy 1–3 gotowe; etap 4 (SFTP/FTP/FTPS/WebDAV): kod i testy gotowe, interfejs niesprawdzony ręcznie na prawdziwych serwerach** (zob. ROADMAP.md).

## Polecenia
```bash
swift test --scratch-path /tmp/oc-spm     # Core (207) + Remote (87; SFTP/WebDAV/FTP/FTPS na serwerach lokalnych w procesie testowym)
xcodegen generate                          # po zmianie project.yml
xcodebuild -project OpenCommander.xcodeproj -scheme OpenCommander -destination 'platform=macOS' -derivedDataPath /tmp/oc-dd build
```
Repo bywa w folderze iCloud (Documents): artefakty buildu trzymaj poza nim (`--scratch-path`, `-derivedDataPath`), inaczej codesign zgłasza „detritus”.

## Struktura
- `Sources/OpenCommanderCore` — Models, FileSystem, Operations, Persistence, Network (cała logika; bez bibliotek sieciowych)
- `Sources/OpenCommanderRemote` — SFTP (Citadel), WebDAV (URLSession), FTP/FTPS (systemowy libcurl przez `Sources/CCurl`)
- `Tests/OpenCommanderCoreTests` — testy na katalogach tymczasowych (+ `FakeProvider`)
- `Tests/OpenCommanderRemoteTests` — testy na serwerach lokalnych (127.0.0.1) w procesie testowym
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

## Połączenia sieciowe — zasady (etap 4)
Zakaz sieciowy został **zniesiony przez właściciela** dla: SFTP, FTP, FTPS (jawny/niejawny), WebDAV (HTTPS; HTTP tylko jako jawnie wybrany, ostrzegany wariant). Inne protokoły i chmury własnościowe nadal wymagają zmiany zakresu.
- **Sekrety:** hasła/passphrase wyłącznie w Keychain (`SecretStore`) albo w pamięci sesji; nigdy w UserDefaults/JSON/SQLite/bookmarkach, kodzie, logach, testach (poza fikcyjnymi hasłami serwerów testowych), repozytorium ani komunikatach błędów (`Redactor`). Klucz prywatny — tylko ścieżka pliku.
- **Nie łącz się z prawdziwymi serwerami** właściciela ani publicznymi (testy wyłącznie na serwerach w procesie testowym na 127.0.0.1). Nie używaj prawdziwych haseł ani kluczy w testach.
- **Nie implementuj SSH, TLS ani kryptografii** samodzielnie. TLS: zawsze weryfikacja certyfikatu i nazwy hosta; nigdy „akceptuj wszystko” (zaufanie można tylko *zawęzić*, np. `CAINFO` w testach). Zwykłe FTP i HTTP tylko po `allowInsecure`; FTPS nigdy nie spada po cichu do FTP.
- **SSH:** nieznany klucz hosta → pytanie z odciskiem, zapis dopiero po akceptacji; zmieniony klucz → blokada bez pytania.
- **Transfery:** tylko kopiowanie lokalne↔zdalne (bez przenoszenia i bez serwer→serwer); źródło lokalne nigdy nie jest usuwane; wysyłanie przez nazwę tymczasową `.opencommander-tmp-*` i weryfikację rozmiaru; pobieranie przez plik tymczasowy w `TempJournal`; nazwy z serwera niezaufane (path traversal, CR/LF); symlinków zdalnych nie rozwijamy; nie deklaruj wznawiania ani atomowości; po utracie połączenia nie ponawiaj automatycznie operacji destrukcyjnych (ponowienie = ręczne, od początku).
- **UI:** usuwanie zdalne to nie Kosz — osobne potwierdzenie z serwerem, ścieżką i liczbą elementów oraz informacją o nieodwracalności. Nie pokazuj funkcji, której dany serwer nie obsługuje.
- **Testowanie aplikacji z połączeniami:** tylko w kopii z innym `CFBundleIdentifier` (jak niżej); serwer testowy: `OC_SERVE_SECONDS=300 swift test --filter SFTPIntegrationTests/testServeForManualUI` (127.0.0.1:2222). Zrzuty i kliknięcia wyłącznie w oknie własnej kopii (po PID).

## Zakres
Bez commitów/pushy bez zgody. Przy dodawaniu zależności: wersja przypięta, licencja sprawdzona i opisana w README. Bez sandboxa (decyzja w ARCHITECTURE.md); bez wymagania Full Disk Access.
