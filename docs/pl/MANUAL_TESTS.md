# Ręczne testy (zależne od systemu)

Wykonuj **wyłącznie na kopiach / katalogach testowych**, nie na ważnych danych. Testy automatyczne (`swift test`) pokrywają logikę; ta lista pokrywa to, czego nie da się sprawdzić bez okna i systemu.

## Przygotowanie
Utwórz folder `~/OC-test` z podfolderami `A` i `B`, w `A` kilka plików (w tym `raport.xlsx`, plik ~1 GB, plik z emoji w nazwie, skrót symboliczny `ln -s`), w `B` plik `raport.xlsx` o innej treści.

## Interfejs i klawiatura
- [ ] Oba panele pokazują folder; kliknięcie w panel czyni go aktywnym (pas u góry, nagłówek drugiego przygaszony).
- [ ] **Tab** w tabeli przełącza panel; **⌘`** też; Tab w polu tekstowym arkusza **nie** przełącza paneli.
- [ ] Strzałki, Shift/⌘-klik: zaznaczanie wielokrotne. **Enter** otwiera folder / plik dokładnie raz.
- [ ] Klik w nagłówek kolumny sortuje; strzałka kierunku się zgadza; sortowanie przeżywa restart aplikacji.
- [ ] **⌘↑**, **⌘[**, **⌘]**, **⌘R**, **⇧⌘N**, **⇧⌘.**, **⇧⌘O**, **F2**, **F5**, **F6**, **⌘⌫** — działają; pozycje menu są wyszarzone, gdy akcja niedostępna (np. brak zaznaczenia).
- [ ] **Esc** zamyka arkusze (nowy folder, zmiana nazwy); w konflikcie = „Anuluj operację”.
- [ ] Widoczny fokus; sprawdź jasny i ciemny motyw oraz małe okno (minimum 900 pt) i duże.
- [ ] VoiceOver czyta nazwy plików, „dowiązanie symboliczne”, aktywny panel, postęp.

## Etap 2A
- [ ] **⌘F** pokazuje pasek filtra, wpisanie „zolc” znajduje „Żółć…”; **Esc** zamyka i czyści; zmiana folderu czyści filtr; kopiowanie/Kosz działa tylko na widocznych po filtrze.
- [ ] **Spacja** na zaznaczonym pliku otwiera Quick Look (strzałki przełączają, Spacja zamyka).
- [ ] Prawy klik na elemencie spoza zaznaczenia zaznacza go; menu: Otwórz, **Otwórz za pomocą** (lista aplikacji), Pokaż w Finderze, Kopiuj ścieżkę, Informacje, ulubione, kopiuj/przenieś, zmiana nazwy, Kosz. Prawy klik na pustym miejscu: nowy folder, odśwież, ukryte.
- [ ] **⌘I** otwiera panel informacji (także **przy starcie aplikacji z otwartym panelem — to było źródłem awarii**); pokazuje typ, daty, uprawnienia, cel dowiązania; „Oblicz rozmiar” dla folderu liczy dopiero po kliknięciu i da się anulować.
- [ ] **⌘D** dodaje/usuwa folder z ulubionych; ulubione i „Ostatnie” w pasku bocznym przeżywają restart; usunięty folder ulubiony jest wyszarzony.

## Etap 2B — karty i przestrzenie
- [ ] **⌘T** (lub przycisk ⊞ w nagłówku) dodaje kartę z tą samą lokalizacją; pasek kart pojawia się przy ≥ 2 kartach; klik przełącza; × i **⌘W** zamykają; **⌘W na ostatniej karcie panelu zamyka okno** — sprawdź też, że w menu Plik nie ma drugiego „Zamknij”.
- [ ] Każda karta ma własną historię (wstecz/dalej), zaznaczenie, sortowanie i filtr; po powrocie do karty wszystko na swoim miejscu.
- [ ] „Otwórz w nowej karcie” z menu kontekstowego folderu; **⇧⌘]** / **⇧⌘[** przełączają karty cyklicznie; limit 10 kart pokazuje komunikat.
- [ ] Karty i aktywna karta przeżywają restart aplikacji; karta z usuniętym folderem otwiera najbliższy istniejący.
- [ ] **Przestrzenie:** ⌥⌘S zapisuje (pusta nazwa i **powtórzona nazwa są odrzucane**); wybór z menu „Przestrzenie” lub paska bocznego przywraca karty obu paneli; „Usuń przestrzeń” działa; przestrzenie przeżywają restart.

## Etap 2C — przeciąganie i odświeżanie
- [ ] Przeciągnięcie pliku/zaznaczenia z jednego panelu na drugi: ten sam wolumin → przeniesienie, z ⌥ → kopia; operacja pojawia się w kolejce.
- [ ] Przeciągnięcie zaznaczenia kilku elementów przenosi wszystkie; przeciągnięcie niezaznaczonego wiersza tylko ten wiersz.
- [ ] Upuszczenie na ten sam folder nic nie robi; konflikt nazw pokazuje dialog.
- [ ] Przeciągnięcie z Findera do panelu działa (zwykle kopia/przeniesienie wg woluminu).
- [ ] Plik dodany/usunięty z Findera lub Terminala pojawia się/znika w panelu w ok. 0,5 s, bez utraty zaznaczenia.

- [ ] **⌘C / ⌘V** (oraz ⌥C / ⌥V) w panelu kopiują zaznaczone pliki i foldery do schowka i wklejają je do folderu aktywnego panelu; wklejenie do Findera i z Findera działa; w polu filtra ⌘C/⌘V działają na tekst.
- [ ] Kliknięcie dysku zewnętrznego w pasku bocznym zawsze otwiera go w prawym panelu (i go aktywuje).

- [ ] **⌘F** wpisanie fragmentu nazwy znajduje pliki w podfolderach (z ścieżką względną obok nazwy); Enter/podwójne kliknięcie na wyniku otwiera plik, a folder wchodzi do niego; przycisk obok pola przełącza na sam filtr bieżącej listy; zmiana folderu czyści wyszukiwanie.

## Etap 3 — narzędzia i układ
- [ ] **⇧⌘R** na zaznaczonych plikach: podgląd zmienia się na bieżąco; kolizje są czerwone i blokują przycisk; po wykonaniu nowe nazwy są zaznaczone.
- [ ] **⇧⌘K** przy dwóch różnych folderach pokazuje różnice; „Kopiuj zaznaczone →/←” przenosi je do kolejki; foldery takie same → „Foldery są takie same”.
- [ ] **Duplikaty:** „Szukaj duplikatów” działa dopiero po kliknięciu; „Przerwij” działa; zaznaczenie wszystkich kopii w grupie jest odrzucane; usunięcie trafia do Kosza.
- [ ] **Separator:** przeciągnięcie zmienia szerokość paneli, nie da się zejść poniżej ok. 250 pt, dwuklik przywraca po równo; start z otwartym panelem informacji bez awarii.
- [ ] Prawy klik na nagłówku tabeli pozwala ukryć kolumny (np. „Rodzaj”) — sprawdź, czy ustawienie działa i się zapamiętuje.
- [ ] Jasny i ciemny motyw wyglądają poprawnie.

- [ ] **Pomoc → Skróty klawiszowe** (⇧⌘/) otwiera okno z listą; sprawdź, czy skróty z listy faktycznie działają.

## Operacje
- [ ] Nowy folder (w tym nazwa z `/`, pusta, istniejąca → czytelny błąd, brak zmian na dysku).
- [ ] Zmiana nazwy; zmiana **samej wielkości liter** (`raport.xlsx` → `Raport.xlsx`).
- [ ] Kopiuj `A→B` z konfliktem: **Pomiń**, **Zachowaj obie** (`… kopia.xlsx`), **Zastąp** (stary ląduje w Koszu — sprawdź w Koszu i „Przywróć”).
- [ ] „Zastosuj do wszystkich” pyta tylko raz. **Esc** / „Anuluj operację” zatrzymuje całość.
- [ ] Kopiowanie w obrębie tego samego folderu (oba panele na `A`) tworzy „… kopia”; Przenieś jest wyłączone.
- [ ] Przenieś do Kosza z potwierdzeniem; element wraca z „Przywróć”. Kosz nie jest opróżniany przez aplikację.
- [ ] Duży plik **na inny wolumin** (dysk zewnętrzny/obraz dysku): pasek bajtów, prędkość, czas, ETA rosną płynnie; **Anuluj w środku** → brak pliku docelowego i tymczasowego, źródło nietknięte.
- [ ] Ten sam wolumin (APFS): kopiowanie jest natychmiastowe (klon) — pasek przeskakuje do końca, to oczekiwane.

## Awarie i środowisko
- [ ] **Zamknij aplikację (Force Quit) w trakcie kopiowania dużego pliku** → po ponownym uruchomieniu komunikat o sprzątaniu; w folderze docelowym nie zostaje `.opencommander-tmp-*`.
- [ ] Odłącz wolumin podczas kopiowania → czytelny błąd, źródło nietknięte.
- [ ] Wolumin tylko do odczytu / brak uprawnień (`chmod 000`) → błąd uprawnień, bez śmieci.
- [ ] Pełny dysk (mały obraz dysku) → komunikat „Brak miejsca”, źródło nietknięte, brak pliku tymczasowego.
- [ ] Folder do własnego potomka → odmowa z komunikatem.
- [ ] Wolumin w pasku bocznym: podłącz/odłącz → lista się odświeża; okruszki dla `/Volumes/X` zaczynają się od „X”.
- [ ] **Wysuwanie:** przycisk ⏏ w pasku bocznym przy pendrive/obrazie dysku wysuwa go; Macintosh HD nie ma przycisku. Po wysunięciu panele, które go pokazywały, wracają do katalogu domowego. ⌘E wysuwa wolumin aktywnego panelu.
- [ ] Wysuwanie woluminu zajętego (plik otwarty w innej aplikacji) → komunikat z powodem, wolumin zostaje.
- [ ] Wysuwanie woluminu, na którym trwa kopiowanie z kolejki → odmowa z komunikatem (najpierw anuluj operację).
- [ ] Pulpit/Dokumenty: system zapyta o zgodę (TCC) — aplikacja nie wymaga Full Disk Access.

## Etap 4 — połączenia sieciowe (na własnym serwerze testowym lub lokalnym serwerze z testów)
Użyj serwera, którego nie używasz do niczego ważnego (np. `OC_SERVE_SECONDS=600 swift test --filter SFTPIntegrationTests/testServeForManualUI` → `127.0.0.1:2222`, użytkownik `ola`). Aplikację uruchamiaj w kopii z innym identyfikatorem pakietu.
- [ ] Pasek boczny → „Połączenia” → **＋**: formularz pokazuje pola zależne od protokołu; FTP i WebDAV po HTTP pokazują ostrzeżenie i wymagają zgody; **Testuj połączenie** zwraca czytelny wynik; zły adres/port/hasło dają odpowiedni komunikat (DNS, odmowa, uwierzytelnianie), bez hasła w treści.
- [ ] Pierwsze połączenie SFTP pokazuje serwer, port, typ klucza i odcisk; „Nie ufaj” przerywa i niczego nie zapisuje; „Zaufaj i połącz” zapisuje (widać w *Połączenia → Zaufane serwery SSH*); po usunięciu zaufania pytanie wraca.
- [ ] Hasło: z zaznaczonym „Zapamiętaj w Keychain” następne połączenie nie pyta; bez zaznaczenia pyta po rozłączeniu; edycja profilu z pustym polem hasła nie zmienia zapisanego hasła.
- [ ] Kliknięcie połączenia otwiera katalog początkowy w aktywnym panelu; okruszki zaczynają się od nazwy połączenia; „w górę” zatrzymuje się na korzeniu serwera; wstecz/dalej działają między lokalnym a zdalnym.
- [ ] Oba panele na różnych serwerach: F5 serwer→serwer odmawia z komunikatem; lokalny→zdalny to wysyłanie, zdalny→lokalny to pobieranie; **F6 (przenieś) jest wyłączone**, gdy któryś panel jest zdalny.
- [ ] Wysyłanie/pobieranie folderu z plikami o nazwach ze spacjami, `#`, `%`, polskimi znakami i emoji; postęp w bajtach, prędkość; **anulowanie** w środku dużego pliku nie zostawia na serwerze pliku ani `.opencommander-tmp-*`.
- [ ] Konflikt nazw przy wysyłaniu: pomiń / zachowaj obie / zastąp — dialog przy „zastąp” mówi, że na serwerze nie ma Kosza; zastąpienie folderu jest odrzucone.
- [ ] **⌘⌫** w panelu zdalnym: pytanie z nazwą serwera, folderem i liczbą elementów oraz informacją o nieodwracalności; po zatwierdzeniu elementy znikają z serwera, a nie trafiają do Kosza.
- [ ] Odłączenie serwera (wyłączenie, Wi-Fi) w trakcie transferu: operacja kończy się błędem z przyciskiem „Ponów nieudane od początku”; po przywróceniu serwera ponowienie działa i następna akcja łączy ponownie.
- [ ] Menu kontekstowe zdalnego elementu nie ma „Pokaż w Finderze”, Quick Look ani ulubionych; Spacja nic nie robi; dwuklik pliku wyjaśnia, że trzeba go skopiować.
- [ ] Usunięcie profilu: pytanie, czy usunąć sekrety z Keychain; po „tylko profil” hasło zostaje w Keychain (Dostęp do pęku kluczy → wpisy usługi `org.opencommander.OpenCommander.connections`).
