# Współtworzenie

1. Przeczytaj [ARCHITECTURE.md](ARCHITECTURE.md) i zasady bezpieczeństwa w [CLAUDE.md](CLAUDE.md).
2. Logika plikowa trafia do `OpenCommanderCore` i **musi mieć testy** na katalogach tymczasowych. Testy nie mogą dotykać prawdziwego Kosza (użyj `FakeTrasher`) ani plików użytkownika.
3. Przed PR: `swift test --scratch-path /tmp/oc-spm` oraz build przez `xcodebuild` (komendy w README).
4. Po zmianie `project.yml` uruchom `xcodegen generate` i dołącz zmieniony `.xcodeproj`.
5. Protokoły sieciowe: tylko te z ROADMAP (etap 4); nowe zależności zewnętrzne wymagają dyskusji (licencja, utrzymanie, przypięta wersja). Testy sieciowe wyłącznie na serwerach lokalnych w procesie testowym — nigdy na serwerach publicznych ani z prawdziwymi danymi logowania.
6. Nie pokazuj w UI funkcji, która nie działa.
