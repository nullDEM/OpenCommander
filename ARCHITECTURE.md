# Architektura

## Podział
```
Sources/OpenCommanderCore/      pakiet SwiftPM — cała logika, testowalna bez UI
  Models/        FileEntry, PanelState, FileOperation(+Report/Progress/Conflict), OperationError
  FileSystem/    DirectoryLister, FileSorter, FileService (mkdir/rename), Locations (woluminy, miejsca)
  Operations/    FileOperationEngine (copy/move/trash), OperationCenter (kolejka, stan dla UI)
  Persistence/   SettingsStore (UserDefaults, JSON)
Tests/OpenCommanderCoreTests/   testy na katalogach tymczasowych
OpenCommander/                  aplikacja (SwiftUI + AppKit)
  App/           punkt wejścia, AppState, menu/skróty, RootView
  Features/Browser/     panel: tabela, okruszki, pasek stanu
  Features/Sidebar/     pasek boczny
  Features/Operations/  obszar operacji, arkusze (nazwa, konflikt)
project.yml     definicja projektu Xcode (XcodeGen)
```
Moduły `Features/Search`, `Features/BatchRename`, `Features/Preview` z planu powstaną w etapach 2–3 (nie ma pustych katalogów).
Karty: `PanelTabs` (Models) trzyma listę `PanelState` — każda karta to pełny stan panelu; `Workspace` to zapis kart obu paneli. Osobny `TabState` nie jest potrzebny.

## Decyzje
- **Minimalne macOS 14.4:** `@Observable`, `onKeyPress`, `defaultScrollAnchor` i dojrzały `Table` z wielokrotnym zaznaczeniem. SDK 27 to udostępnia; macOS 13 wymagałby `ObservableObject` i obejść.
- **Brak App Sandbox:** menedżer plików musi działać na dowolnych folderach, a sandbox wymusza security-scoped bookmarks dla każdej lokalizacji, w tym przy każdym starcie i dla przeglądania całego dysku — w praktyce psuje główny scenariusz produktu. Aplikacja jest podpisywana z Hardened Runtime i **nie żąda Full Disk Access**; dostęp do chronionych folderów (Pulpit, Dokumenty, woluminy zewnętrzne) obsługuje standardowy mechanizm zgód systemu (TCC). Konsekwencja: dystrybucja poza Mac App Store. Zmiana tej decyzji wymaga dodania bookmarków (zob. ROADMAP).
- **Tożsamość pliku = ścieżka** (`FileEntry.id`), nigdy indeks w tabeli. Po rename/przeniesieniu panel jawnie zaznacza nowy URL. Wpisy budowane są od podanego folderu (system potrafi zwracać `/private/var` zamiast `/var`).
- **Nieaktualne wyniki:** `PanelState` numeruje ładowania (`generation`) i anuluje poprzednie zadanie; wynik starszego ładowania jest odrzucany. Nieudana nawigacja zostawia poprzednią lokalizację i pokazuje błąd.
- **Współbieżność:** listowanie w `Task.detached` z propagacją anulowania; operacje plikowe w silniku poza głównym wątkiem; `OperationCenter` (MainActor) uruchamia jedno zadanie naraz.
- **Silnik operacji:** kopia → plik tymczasowy `.opencommander-tmp-<uuid>` w folderze docelowym → zmiana nazwy. Ten sam wolumin: przenoszenie przez `rename`; inny wolumin: kopia, a źródło usuwane po sukcesie. Zastąpienie: stary element do Kosza (wstrzykiwany `Trashing`, w testach atrapa), nowy dopiero po tym. Kopiowanie idzie przez `copyfile(3)` (`FileCopier`): metadane, klonowanie APFS gdy możliwe, postęp bajtowy z callbacka i przerwanie w środku pliku (plik tymczasowy usuwany, źródło nietknięte). Rozmiar całości liczony z metadanych przed startem (bez czytania zawartości).
- **Dziennik plików tymczasowych** (`TempJournal`, Application Support): wpis przed pierwszą zmianą na dysku. Rodzaj `copy` (niepełna kopia) jest usuwany przy starcie; rodzaj `movedSource` (oryginał chwilowo pod nazwą tymczasową przy rename) jest **przywracany**, nigdy usuwany. Sprzątanie dotyka tylko plików z prefiksem `.opencommander-tmp-`.
- **Dowiązania symboliczne** są kopiowane jako dowiązania; ochrona przed kopiowaniem do potomka działa na ścieżkach z rozwiniętymi dowiązaniami i bez rozróżniania wielkości liter (zachowawczo).
- **Postęp:** bajty tam, gdzie mierzone (kopiowanie danych), inaczej elementy. `OperationCenter` wygładza prędkość (EMA) i szacuje czas do końca; klonowanie APFS i przenoszenie przez rename są natychmiastowe, więc nie dają postępu pośredniego.

- **Odświeżanie:** `DirectoryWatcher` (DispatchSource na deskryptorze folderu, opóźnienie 0,3 s) w `PanelState`; zgłasza zmiany bezpośrednich dzieci folderu. To nie FSEvents — nie widzi zmian głęboko w drzewie ani zawartości plików.
- **Upuszczanie:** `DropPlanner` (Core) wybiera przeniesienie/kopię i odsiewa elementy już leżące w celu; wykonanie przez zwykłą kolejkę `OperationCenter`, więc działają wszystkie zabezpieczenia silnika.
- **Narzędzia etapu 3 (Core, testowane):** `BatchRename` (plan → wykonanie tylko pozycji `ok`, bez nadpisań), `FolderComparison` (metadane, foldery jednostronne nie są rozwijane), `DuplicateFinder` (rozmiar → SHA-256, anulowalny, tylko na żądanie), `RecursiveSearch`. UI w `Features/Tools`.
- **Separator paneli:** własny `Layout` (`TwoPaneSplit`) — przesunięcie w pikselach przycinane w układzie, bez `GeometryReader` i bez `HSplitView`.
- **Karty:** zawsze ≥ 1 karta w panelu (ostatniej nie da się zamknąć — ⌘W zamyka wtedy okno), limit 10; nowa karta duplikuje lokalizację i sortowanie aktywnej; karta w tle odświeża się przy wyborze. `AppState` tworzy karty fabryką ze słabą referencją do siebie (tworzenie w `init`, zanim `self` jest gotowy).
- **Przestrzenie robocze:** zapis = migawka kart obu paneli (+ aktywna karta i panel); otwarcie zastępuje wszystkie karty. Ustawienia z wcześniejszych wersji (bez kart) nadal się wczytują.
- **Bez `HSplitView` między panelami:** zagnieżdżony widok dzielony (`HSplitView`) wewnątrz `NavigationSplitView` z `.inspector` wpadał w pętlę zmian minimalnych rozmiarów i wywalał aplikację przy starcie z otwartym panelem informacji (powtarzalnie 8/8 w izolowanym teście; po zamianie na `HStack` 0 awarii w 16 startach). Skutek: dwa równe panele, bez przeciąganego podziału (do rozważenia własny uchwyt bez `GeometryReader`).
- **Okruszki:** `ScrollView` + jawne przewijanie do znacznika końca; żadnego sprzężenia rozmiaru z kontenerem.
- **Filtr ≠ wyszukiwanie:** filtr działa na załadowanych wpisach panelu (`FileFilter`), zawsze obcina zaznaczenie do widocznych; wyszukiwanie rekurencyjne to osobna funkcja etapu 3.
- **Rozmiar folderu:** wyłącznie na żądanie (`FolderSizer`), anulowalny, zgłasza elementy nieczytelne zamiast je ukrywać.

## Znane ograniczenia architektury
- Brak obserwacji zmian w systemie plików (FSEvents) — odświeżanie po operacjach i ⌘R.
- Przed kopiowaniem przeglądane są metadane całego drzewa (suma rozmiarów) — dla ogromnych drzew to chwila bez paska.
