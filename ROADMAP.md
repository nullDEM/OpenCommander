# Roadmap

Zakres: **wyłącznie lokalny**. Funkcje sieciowe (FTP/SFTP/chmury, profile połączeń) są poza zakresem; ich dodanie wymaga jawnej zmiany zakresu.

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

## Później
- bezpieczna synchronizacja lokalnych folderów, archiwa, historia operacji
- rozważenie App Sandbox + security-scoped bookmarks (dystrybucja MAS)
- lokalizacje (en)
