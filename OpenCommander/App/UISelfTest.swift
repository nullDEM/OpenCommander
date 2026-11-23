#if DEBUG
import AppKit
import OpenCommanderCore

/// Test interfejsu listy plików wysyłający zdarzenia klawiatury i myszy wewnątrz procesu (bez uprawnień Dostępności).
/// Tylko w buildach Debug i tylko ze zmienną `OC_UI_SELFTEST=1`; wyniki na standardowe wyjście, potem zamknięcie aplikacji.
/// Przeznaczony do kopii testowej (inny bundle id) z danymi w katalogu tymczasowym.
@available(macOS 15.0, *)
@MainActor
enum UISelfTest {
    private static var started = false
    private static var failures = 0

    static func startIfRequested(_ state: AppState) {
        guard ProcessInfo.processInfo.environment["OC_UI_SELFTEST"] == "1", !started else { return }
        started = true
        Task { @MainActor in
            await run(state)
            print("SELFTEST KONIEC: \(failures == 0 ? "OK" : "BŁĘDÓW: \(failures)")")
            fflush(stdout)
            exit(failures == 0 ? 0 : 1)
        }
    }

    private static func check(_ ok: Bool, _ what: String) {
        if !ok { failures += 1 }
        print("\(ok ? "✔" : "✘") \(what)")
        fflush(stdout)
    }

    private static func wait(_ seconds: Double = 0.4) async { try? await Task.sleep(for: .seconds(seconds)) }

    private static func tables(in window: NSWindow) -> [NSTableView] {
        var found: [NSTableView] = []
        func walk(_ v: NSView) { if let t = v as? NSTableView, t.numberOfColumns >= 4 { found.append(t) }; v.subviews.forEach(walk) }
        if let content = window.contentView { walk(content) }
        return found.sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
    }

    private static func key(_ window: NSWindow, _ code: UInt16, _ chars: String, _ flags: NSEvent.ModifierFlags = []) async {
        let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: window.windowNumber, context: nil, characters: chars,
                                  charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
        window.sendEvent(ev)
        await wait()
    }

    /// Kliknięcie dostarczane wprost do widoku pod punktem (jak `NSWindow.sendEvent` dla okna kluczowego). Okno kopii
    /// testowej zwykle nie jest kluczowe (inne biurko), a wtedy system traktuje pierwsze kliknięcie tylko jako aktywację.
    private static func click(_ window: NSWindow, at point: NSPoint, count: Int = 1, flags: NSEvent.ModifierFlags = []) async {
        guard let content = window.contentView?.superview ?? window.contentView,
              let target = content.hitTest(content.convert(point, from: nil)) else { check(false, "widok pod punktem \(point)"); return }
        for n in 1...count {
            let t = ProcessInfo.processInfo.systemUptime
            let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: flags, timestamp: t,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: n, pressure: 1)!
            let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: flags, timestamp: t + 0.01,
                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: n, pressure: 0)!
            NSApp.postEvent(up, atStart: false)   // pętla śledzenia myszy czeka na „puszczenie”
            if ProcessInfo.processInfo.environment["OC_UI_DEBUG"] == "1" { print("  · klik \(n)× w \(type(of: target))") }
            if window.isKeyWindow { NSApp.sendEvent(down) } else { target.mouseDown(with: down) }
            await wait(0.15)
        }
        await wait()
    }

    private static func rowPoint(_ table: NSTableView, _ row: Int) -> NSPoint {
        table.scrollRowToVisible(row)
        let r = table.rect(ofRow: row)
        return table.convert(NSPoint(x: r.minX + 60, y: r.midY), to: nil)
    }

    private static func run(_ state: AppState) async {
        await wait(3)
        guard let window = NSApp.windows.first(where: { !tables(in: $0).isEmpty }) else { check(false, "okno z tabelami"); return }
        let ts = tables(in: window)
        check(ts.count == 2, "dwie tabele NSTableView (szybka lista)")
        guard ts.count == 2 else { return }
        let (lt, rt) = (ts[0], ts[1])
        let left = state.left, right = state.right
        check(lt.numberOfRows == left.visibleEntries.count && rt.numberOfRows == right.visibleEntries.count,
              "liczba wierszy = liczba wpisów (\(lt.numberOfRows), \(rt.numberOfRows))")

        // Prawdziwa ścieżka zdarzeń wymaga okna kluczowego (nieaktywne okno traktuje kliknięcie tylko jako aktywację).
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        await wait(1)
        print("okno kluczowe: \(window.isKeyWindow)")
        let startActive = state.active
        check(window.firstResponder === (startActive == .left ? lt : rt), "fokus klawiatury na aktywnym panelu po starcie (\(startActive))")

        await key(window, 48, "\t")
        check(state.active != startActive, "Tab przełącza aktywny panel")
        check(window.firstResponder === (state.active == .left ? lt : rt), "Tab przenosi fokus na drugą tabelę")
        await key(window, 48, "\t")
        check(state.active == startActive, "Tab wraca do pierwszego panelu")

        // Klawiatura w lewej tabeli
        if state.active != .left { await key(window, 48, "\t") }
        left.selection = []
        await wait()
        await key(window, 125, "\u{F701}")
        check(left.selection.count == 1 && left.selection.first == left.visibleEntries.first?.id, "strzałka w dół zaznacza pierwszy wiersz")
        await key(window, 125, "\u{F701}")
        check(left.selection.first == left.visibleEntries[1].id, "druga strzałka przechodzi do drugiego wiersza")
        await key(window, 125, "\u{F701}", .shift)
        check(left.selection.count == 2, "Shift+strzałka rozszerza zaznaczenie (\(left.selection.count))")

        // Zaznaczenie ustawione w stanie panelu (np. „Zaznacz wszystko”) trafia do tabeli
        left.selection = Set(left.visibleEntries.prefix(5).map(\.id))
        await wait()
        check(lt.selectedRowIndexes == IndexSet(0..<5), "zaznaczenie ze stanu panelu widoczne w tabeli")

        // Kliknięcie w prawą tabelę: aktywuje panel i zaznacza wiersz
        let target = min(3, right.visibleEntries.count - 1)
        await click(window, at: rowPoint(rt, target))
        check(state.active == .right, "klik w prawą tabelę aktywuje prawy panel")
        check(right.selection == [right.visibleEntries[target].id], "klik zaznacza kliknięty wiersz (tabela: \(Array(rt.selectedRowIndexes)), oczekiwano \(target))")
        check(window.firstResponder === rt, "klik daje fokus prawej tabeli")
        await click(window, at: rowPoint(rt, target + 2), flags: .command)
        check(right.selection.count == 2, "⌘-klik dodaje do zaznaczenia")

        // Sortowanie: AppKit po kliknięciu nagłówka ustawia `sortDescriptors` — sprawdzamy powiązanie z panelem
        // (syntetyczne kliknięcia w nagłówek okazały się zawodne jako sam test).
        rt.sortDescriptors = [NSSortDescriptor(key: "size", ascending: true), NSSortDescriptor(key: "name", ascending: true)]
        await wait(0.8)
        check(right.sortKey == .size && right.sortAscending, "sortowanie z tabeli trafia do panelu (rozmiar ↑)")
        check(rt.sortDescriptors.count == 1 && rt.sortDescriptors[0].key == "size", "tabela trzyma jeden deskryptor zgodny z panelem")
        rt.sortDescriptors = [NSSortDescriptor(key: "size", ascending: false)]
        await wait(0.8)
        check(right.sortKey == .size && !right.sortAscending, "odwrócenie kierunku (rozmiar ↓)")
        right.setSort(key: .name, ascending: true)
        await wait(0.8)
        check(rt.sortDescriptors.first?.key == "name" && rt.sortDescriptors.first?.ascending == true, "sortowanie z panelu widoczne w nagłówku")

        // Dwuklik w folder: wejście do środka
        if let folderRow = right.visibleEntries.firstIndex(where: \.isNavigable) {
            let folder = right.visibleEntries[folderRow]
            await click(window, at: rowPoint(rt, folderRow), count: 2)
            await wait(1.5)
            check(right.location.standardizedFileURL == folder.url.standardizedFileURL, "dwuklik wchodzi do folderu „\(folder.name)”")
            check(rt.numberOfRows == right.visibleEntries.count, "tabela pokazuje zawartość nowego folderu (\(rt.numberOfRows))")
            right.goBack()
            await wait(1.5)
        }

        // Return na zaznaczonym folderze
        if let folder = right.visibleEntries.first(where: \.isNavigable) {
            right.selection = [folder.id]
            await wait()
            window.makeFirstResponder(rt)
            await key(window, 36, "\r")
            await wait(1.5)
            check(right.location.standardizedFileURL == folder.url.standardizedFileURL, "Return otwiera zaznaczony folder")
            right.goBack()
            await wait(1.5)
        }

        // Filtr: tabela pokazuje tylko pasujące wpisy
        left.filterText = "Folder 1"
        await wait(0.8)
        check(lt.numberOfRows == left.visibleEntries.count && lt.numberOfRows < 50, "filtr zawęża wiersze tabeli (\(lt.numberOfRows))")
        left.filterText = ""
        await wait(0.8)

        // Ukrycie i pokazanie panelu
        state.setPanelVisible(.left, false)
        await wait(0.8)
        check(tables(in: window).count == 1, "ukrycie lewego panelu zostawia jedną tabelę")
        state.setPanelVisible(.left, true)
        await wait(0.8)
        check(tables(in: window).count == 2, "pokazanie lewego panelu przywraca dwie tabele")

        // Kolumny: widoczność z menu nagłówka
        if let menu = rt.headerView?.menu {
            menu.delegate?.menuNeedsUpdate?(menu)
            check(menu.items.map(\.title) == ["Rozmiar", "Rodzaj", "Zmodyfikowano"], "menu nagłówka: przełączniki kolumn")
            if let kind = menu.items.first(where: { $0.title == "Rodzaj" }), let action = kind.action {
                NSApp.sendAction(action, to: kind.target, from: kind)
                check(rt.tableColumn(withIdentifier: .init("kind"))?.isHidden == true, "ukrycie kolumny „Rodzaj”")
                NSApp.sendAction(action, to: kind.target, from: kind)
                check(rt.tableColumn(withIdentifier: .init("kind"))?.isHidden == false, "przywrócenie kolumny „Rodzaj”")
            }
        }

        // Menu kontekstowe: budowa (bez otwierania — to pętla modalna)
        if let ft = rt as? FileTableView {
            let ev = NSEvent.mouseEvent(with: .rightMouseDown, location: rowPoint(rt, 0), modifierFlags: [], timestamp: 0,
                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            let menu = ft.menu(for: ev)
            menu?.update()
            let titles = menu?.items.map(\.title) ?? []
            check(titles.contains("Otwórz") && titles.contains { $0.contains("drugiego panelu") }, "menu kontekstowe wiersza (\(titles.prefix(4).joined(separator: ", "))…)")
        }
    }
}
#endif
