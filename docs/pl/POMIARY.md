# Pomiary wydajności — punkt odniesienia (etap 0)

Data: 2026-11-23 · commit bazowy `b821359` · MacBook Pro M3 Pro (Mac15,6, 12 rdzeni, 18 GB), macOS 27.0.1, APFS na SSD.
Build: Release. Dane: `python3 Tools/bench/make-data.py /tmp/oc-bench` (deterministyczne, ~3,2 GB).
Pamięć podręczna systemu plików ciepła (pierwszy przebieg to rozgrzewka) — czasy z zimnego dysku będą dłuższe.

Powtórzenie:
```bash
python3 Tools/bench/make-data.py /tmp/oc-bench
swift run -c release --scratch-path /tmp/oc-spm-rel OCBench /tmp/oc-bench            # wszystko
swift run -c release --scratch-path /tmp/oc-spm-rel OCBench /tmp/oc-bench rozbicie   # tylko wybrane pomiary
```

## 1. Logika Core (`OCBench`)

| Pomiar | Mediana [ms] | Min [ms] | n | Uwagi |
|---|---:|---:|---:|---|
| listowanie flat_1k | 88,1 | 87,6 | 5 | 1 000 wpisów |
| listowanie flat_10k | 890,2 | 889,2 | 5 | 10 000 wpisów |
| **listowanie flat_50k** | **4 744,5** | 4 691,9 | 5 | 50 000 wpisów (~95 µs na wpis) |
| sortowanie 50k po name ↑ | 416,9 | 397,5 | 5 | |
| sortowanie 50k po size ↑ | 202,8 | 196,0 | 5 | |
| sortowanie 50k po kind ↑ | 438,5 | 428,1 | 5 | |
| sortowanie 50k po date ↑ | 177,7 | 171,2 | 5 | |
| sortowanie 50k po name ↓ | 383,0 | 380,4 | 5 | |
| sortowanie 50k już posortowanej po name | 18,3 | 17,9 | 5 | |
| filtr 50k: pisanie „raport 2” (8 znaków) | 168,5 | 167,6 | 5 | ~21 ms na naciśnięcie |
| filtr 50k: „zolc” | 21,0 | 20,9 | 5 | 2 692 wyników |
| rozmiar folderu tree_a | 559,1 | 542,6 | 3 | 100 000 plików, 2 549 folderów |
| porównanie folderów tree_a ↔ tree_b | 2 308,1 | 2 277,7 | 3 | 3 000 różnic |
| **duplikaty tree_a (100 000 małych plików)** | **16 790,8** | 15 967,0 | 3 | prawie każdy plik ma „bliźniaka” rozmiarem → hashowanie ~100 000 plików |
| duplikaty dups (~2,2 GB) | 608,1 | 592,1 | 3 | 9 grup; szybki hash odcina większość pracy |

Szczytowa pamięć procesu benchmarku: 1 345 MB.

### Rozbicie kosztu listowania (10 000 wpisów)

| Wariant | ms |
|---|---:|
| same nazwy (`contentsOfDirectory(atPath:)`) | 29 |
| atrybuty podstawowe, **URL zwrócony przez system** | **56** |
| atrybuty podstawowe, URL budowany na nowo (`appendingPathComponent`, jak w `DirectoryLister`) | 332 |
| + `contentTypeKey` | 390 |
| + `localizedTypeDescriptionKey` | 819 |
| komplet (jak `DirectoryLister`) | 855 |

Wnioski:
1. **Przebudowa URL w `DirectoryLister.listSync` gubi wstępnie pobrane atrybuty** (`includingPropertiesForKeys`) — każdy wpis jest odczytywany z dysku drugi raz: ~6× wolniej (56 → 332 ms).
2. **`localizedTypeDescriptionKey` kosztuje ~45 µs na wpis** (zapytanie do LaunchServices) — połowa czasu listowania. Opis rodzaju zależy tylko od typu (UTType), więc można go liczyć raz na typ (pamięć podręczna).
3. Łącznie realny cel: listowanie 50k z ~4,7 s do ~0,4–0,6 s, bez zmiany języka.

## 2. Aplikacja (Instruments, Time Profiler)

Scenariusz: start aplikacji (kopia testowa, bundle id `.test`) z oboma panelami w `flat_50k`; profil przez podpięcie do procesu, 12 s, próbki co 1 ms.

| Kategoria | Razem [ms CPU] | Wątek główny [ms] |
|---|---:|---:|
| listowanie (`DirectoryLister`, `resourceValues`) | 7 776 | 0 |
| sortowanie (`FileSorter`, `localizedStandardCompare`) | 1 008 | 0 |
| tabela (NSTableView / SwiftUI OutlineTable: wiersze, automatyczne wysokości) | 2 093 | **2 093** |
| aktualizacja grafu SwiftUI (AttributeGraph) | 1 210 | 1 210 |
| filtr / składanie nazw | 210 | 0 |

Wnioski:
1. Listowanie i sortowanie są już poza wątkiem głównym (nie blokują UI), ale trwają kilka sekund — użytkownik czeka na zawartość.
2. **Wątek główny spędza ~2,1 s w tabeli** przy wstawieniu 50 000 wierszy — to widoczne przycięcie interfejsu. Profil wskazuje na **automatyczne wysokości wierszy** (`_doAutomaticRowHeightsForInsertedAndVisibleRows`, `_uncachedAutomaticRowHeight`) i różnicowanie wierszy w `AppKitOutlineTableCoordinator`.

## 3. Priorytety dla etapu 1 (na podstawie liczb)

| # | Problem | Pomiar | Proponowana zmiana | Oczekiwany zysk |
|---|---|---|---|---|
| 1 | Listowanie | 4,7 s / 50k | używać URL z `contentsOfDirectory`; opis rodzaju z pamięci podręcznej po UTType | ~8–10× |
| 2 | Tabela na wątku głównym | 2,1 s / 50k | stała wysokość wiersza zamiast automatycznej; ograniczenie przebudowy wierszy | do sprawdzenia; ewentualnie `NSTableView` (etap 3) |
| 3 | Duplikaty w drzewie małych plików | 16,8 s / 100k (~170 µs na plik) | najpierw profil (otwieranie plików, `String(format:)` przy zamianie skrótu na tekst, `resourceValues` w enumeratorze); potem hashowanie równoległe | ~3–6× (do potwierdzenia) |
| 4 | Porównanie folderów | 2,3 s / 100k | URL z systemu (jak pkt 1), równoległość | ~3× |
| 5 | Sortowanie | 0,4 s / 50k | klucz sortowania liczony raz | ~3–5× |

**Rust: obecnie niepotrzebny.** Hashowanie dużych plików (2,2 GB) trwa 0,6 s — CPU nie jest wąskim gardłem. Wszystkie największe koszty wynikają z dodatkowych wywołań systemowych i pracy interfejsu, których zmiana języka nie usunie.
