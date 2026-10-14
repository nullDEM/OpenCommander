# Roadmap

Zakres: pliki lokalne oraz **SFTP, FTP, FTPS i WebDAV** (etap 4). Zakaz sieciowy z wcześniejszych etapów został świadomie zniesiony przez właściciela; chmury własnościowe (Dropbox, iCloud Drive API, S3…) nadal nie są w zakresie.

## Etap 1 — zrobiony (0.1)
Dwa panele, tabela, sortowanie, zaznaczanie, nawigacja, okruszki, ukryte, otwieranie, nowy folder, rename, kopiuj/przenieś/Kosz, konflikty, kolejka, ustawienia. Zob. README.

## Etap 2 — w toku (partie A, B i C zrobione; schowek plików — niezrealizowany)
- [x] karty w panelach (`PanelTabs`; każda karta to `PanelState`)
- [x] ulubione i ostatnie lokalizacje
- [x] Quick Look (spacja)
- [x] menu kontekstowe (w tym „Otwórz za pomocą”, pokaż w Finderze, kopiuj ścieżkę)
- [x] drag-and-drop między panelami i schowek plików (⌘C/⌘V)
- [x] filtr bieżącego folderu
- [x] panel informacji, rozmiar folderu na żądanie
- [x] przestrzenie robocze (`Workspace`)
- [ ] wpisywanie ścieżki, widok ikon
- [x] przeciągalny podział między panelami (własny Layout, bez HSplitView)
- [x] automatyczne odświeżanie folderu (DispatchSource, nie pełny FSEvents)

## Etap 3
- [x] wyszukiwanie rekurencyjne (anulowalne)
- [x] masowa zmiana nazw z podglądem i wykrywaniem kolizji (zamiany/łańcuchy są odrzucane, nie obsługiwane)
- [x] porównywanie folderów, wyszukiwanie duplikatów (hash tylko na żądanie)

## Etap 4 — połączenia sieciowe (kod i testy gotowe; interfejs sprawdzony tylko kompilacją i testami logiki)
- [x] warstwa wspólna: `RemoteLocation` (`ocremote://`), `ConnectionProfile` bez sekretów, `FileProvider`, `NetworkError`, Keychain (`SecretStore`), zaufane hosty SSH
- [x] SFTP (Citadel): hasło i klucz, lista, pobieranie, wysyłanie, mkdir, rename, usuwanie, TOFU kluczy hosta
- [x] WebDAV (URLSession): HTTPS, HTTP z ostrzeżeniem, PROPFIND/GET/PUT/MKCOL/MOVE/DELETE
- [x] FTP i FTPS jawny/niejawny (systemowy libcurl): tryb pasywny, MLSD z zapasowym LIST
- [x] kolejka: wysyłanie/pobieranie katalogów, anulowanie, ręczne „Ponów od początku”, konflikty, zdalne usuwanie z potwierdzeniem
- [x] interfejs: sekcja „Połączenia”, menedżer, formularz per protokół, test połączenia, pytania o hasło i klucz hosta, widok zaufanych serwerów
- [ ] ręczne przejście interfejsu na prawdziwym serwerze (lista w [MANUAL_TESTS.md](MANUAL_TESTS.md))
- [ ] wznawianie transferów, równoległe transfery, otwieranie plików zdalnych (pobranie do tymczasowego i otwarcie), obserwator zmian
- [ ] klucze ECDSA / format PEM w SFTP, import `known_hosts`

## Później
- bezpieczna synchronizacja lokalnych folderów, archiwa, historia operacji
- rozważenie App Sandbox + security-scoped bookmarks (dystrybucja MAS)
- lokalizacje (en)
