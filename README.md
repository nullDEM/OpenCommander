# OpenCommander

**Natywny, lokalny, dwupanelowy menedżer plików na macOS** (SwiftUI + AppKit), open source — alternatywa dla Findera dla osób pracujących z dużą liczbą plików.
*(EN: a native, local-only, dual-pane file manager for macOS. UI language: Polish.)*

<p align="center">
  <img src="docs/screenshots/dark.png" alt="OpenCommander — ciemny motyw, dwa panele z kartami" width="900"><br>
  <img src="docs/screenshots/light.png" alt="OpenCommander — jasny motyw" width="900">
</p>

> **Zakres:** wyłącznie pliki lokalne (dysk, wybrane foldery, zamontowane woluminy). Brak FTP/SFTP/chmur i jakichkolwiek połączeń sieciowych — to świadoma decyzja. Aplikacja nie zbiera żadnych danych.

## Status
Wczesna wersja **0.1**. Logika plikowa jest pokryta testami automatycznymi (SwiftPM, wyłącznie na katalogach tymczasowych), ale **interfejs jest sprawdzany ręcznie** — lista rzeczy do przeklikania jest w [MANUAL_TESTS.md](MANUAL_TESTS.md). Spodziewaj się błędów; zgłaszaj je przez Issues. Interfejs jest po polsku (bez systemu lokalizacji).

Aplikacja **nie jest notaryzowana** ani podpisana certyfikatem dewelopera — zbuduj ją ze źródeł (poniżej). Działa bez sandboxa i bez Full Disk Access (uzasadnienie: [ARCHITECTURE.md](ARCHITECTURE.md)).

## Funkcje
**Przeglądanie**
- Dwa niezależne panele; **karty** w każdym (⌘T, do 10 na panel) i **przestrzenie robocze** (zapis/przywracanie kart obu paneli).
- Tabela z wielokrotnym zaznaczaniem i sortowaniem, okruszki ścieżki, historia, przeciągany separator paneli, konfigurowalne kolumny.
- Pasek boczny: ulubione, miejsca, woluminy (z przyciskiem **wysuń** dla USB/kart/obrazów dysków — dysk systemowy nigdy), ostatnie lokalizacje.
- **Szukanie (⌘F)** po nazwie w folderze i podfolderach (bez rozróżniania wielkości liter i polskich znaków), Quick Look na Spacji, panel informacji (⌘I) z rozmiarem folderu liczonym tylko na żądanie.
- Automatyczne odświeżanie po zmianach w otwartym folderze.

**Operacje na plikach**
- Kopiowanie, przenoszenie, zmiana nazwy, nowy folder, Kosz; **schowek plików** (⌘C / ⌘V, także do i z Findera) oraz **przeciąganie** między panelami i z Findera.
- Kolejka operacji z paskiem postępu na żywo (bajty, prędkość, szacowany czas do końca), anulowanie także w środku dużego pliku.
- Dialog konfliktów: pomiń / zachowaj obie / zastąp (zastąpiony element trafia do Kosza).

**Narzędzia**
- **Zbiorcza zmiana nazw** (⇧⌘R) z podglądem „przed → po” i blokadą kolizji.
- **Porównanie folderów** (⇧⌘K) po nazwie, rozmiarze i dacie, z kopiowaniem różnic.
- **Wyszukiwanie duplikatów** po zawartości (SHA-256) — uruchamiane wyłącznie na żądanie; usuwanie tylko do Kosza i zawsze z zachowaniem jednej kopii.

Pełna lista skrótów: menu **Pomoc → Skróty klawiszowe** (⇧⌘/) oraz tabela poniżej.

## Bezpieczeństwo danych
- Nic nie jest nadpisywane domyślnie; usuwanie z poziomu UI to zawsze Kosz.
- Przy przenoszeniu między woluminami źródło jest usuwane dopiero po udanej kopii; kopiowanie folderu do samego siebie jest blokowane; dowiązania symboliczne są kopiowane jako dowiązania.
- Pliki tymczasowe są rejestrowane w dzienniku — po przerwanej sesji niedokończone kopie są sprzątane, a elementy przerwane w trakcie przenoszenia **przywracane**, nie kasowane.
- Rozmiary folderów i skróty zawartości są liczone tylko po akcji użytkownika; listowanie nie czyta zawartości plików.

Szczegóły i zasady dla współtwórców: [CLAUDE.md](CLAUDE.md#zasady-bezpieczeństwa-operacji).

## Wymagania i budowanie
macOS 14.4+ (minimalny rozmiar okna 900 pt), Xcode 15+ (rozwijane na Xcode 27 / Swift 6.4).

```bash
# testy logiki (SwiftPM)
swift test --scratch-path /tmp/oc-spm

# aplikacja
xcodebuild -project OpenCommander.xcodeproj -scheme OpenCommander \
  -destination 'platform=macOS' -derivedDataPath /tmp/oc-dd build
open /tmp/oc-dd/Build/Products/Debug/OpenCommander.app
```
Projekt Xcode jest generowany z `project.yml` ([XcodeGen](https://github.com/yonaskolb/XcodeGen)); `OpenCommander.xcodeproj` jest w repozytorium, więc XcodeGen nie jest potrzebny do zwykłego budowania.
Jeśli repozytorium leży w folderze synchronizowanym z iCloud (np. Documents), podpisywanie może zgłosić „detritus” — buduj z `-derivedDataPath` poza tym folderem, jak wyżej.

## Skróty klawiszowe
| Skrót | Akcja |
|---|---|
| Tab, ⌘` | przełącz panel |
| Enter, ⌘↓ | otwórz |
| ⌘↑ / ⌘[ / ⌘] | folder nadrzędny / wstecz / dalej |
| ⌘R | odśwież |
| ⇧⌘N / ⇧⌘O | nowy folder / wybierz folder |
| F2 | zmień nazwę |
| F5 / F6 | kopiuj / przenieś do drugiego panelu |
| ⌘C / ⌘V (też ⌥C / ⌥V) | kopiuj / wklej pliki |
| ⌥⌘C | kopiuj ścieżkę |
| ⌘⌫ | do Kosza (z potwierdzeniem) |
| ⌘E | wysuń wolumin aktywnego panelu |
| ⌥⌘R | pokaż w Finderze |
| ⌘F | szukaj w folderze i podfolderach (Esc zamyka) |
| Spacja | szybki podgląd |
| ⌘I | panel informacji |
| ⇧⌘. | pliki ukryte |
| ⌘D | dodaj/usuń folder z ulubionych |
| ⌘T / ⌘W | nowa karta / zamknij kartę (ostatnia karta panelu zamyka okno) |
| ⇧⌘] / ⇧⌘[ | następna / poprzednia karta |
| ⌥⌘S | zapisz przestrzeń roboczą |
| ⇧⌘R | zbiorcza zmiana nazw |
| ⇧⌘K | porównaj foldery |
| ⇧⌘/ | lista skrótów |

Klawisze F wymagają Fn albo włączonej opcji „Używaj klawiszy F1, F2 itd. jak standardowych”; wszystkie akcje są też w menu.

## Znane ograniczenia
- W wąskich panelach (np. przy otwartym panelu informacji) kolumny „Rodzaj” i „Zmodyfikowano” mogą się ucinać — widoczność kolumn zmienisz prawym kliknięciem na nagłówku tabeli albo poszerz panel przeciągając separator.
- Automatyczne odświeżanie widzi zmiany bezpośrednio w otwartym folderze, nie w podfolderach ani w zawartości plików.
- Zbiorcza zmiana nazw odrzuca zamiany i łańcuchy nazw (a→b, b→a) zamiast je obsługiwać.
- Plan prac i to, czego jeszcze nie ma: [ROADMAP.md](ROADMAP.md).

## Współtworzenie
Zob. [CONTRIBUTING.md](CONTRIBUTING.md). Logika plikowa musi mieć testy na katalogach tymczasowych; funkcje sieciowe są poza zakresem.

## Licencja i autorstwo
MIT — zob. [LICENSE](LICENSE). Ikona aplikacji: [Tools/icon](Tools/icon/README.md) (zaprojektowana z użyciem skilla [logo-design](https://github.com/kaankiziltug/logo-design-skill), MIT).
