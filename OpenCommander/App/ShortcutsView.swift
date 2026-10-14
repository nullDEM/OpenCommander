import SwiftUI

/// Podsumowanie skrótów klawiszowych (Pomoc → Skróty klawiszowe). Lista odpowiada menu i obsłudze klawiszy w panelach.
struct ShortcutsView: View {
    private struct Item: Identifiable { let id = UUID(); let keys: String; let text: String }
    private struct Group: Identifiable { let id = UUID(); let title: String; let items: [Item] }

    private static func g(_ title: String, _ rows: [(String, String)]) -> Group {
        Group(title: title, items: rows.map { Item(keys: $0.0, text: $0.1) })
    }

    private let groups: [Group] = [
        g("Nawigacja", [
            ("Tab", "przełącz aktywny panel"),
            ("⌘`", "przełącz panel (z menu)"),
            ("Enter  /  ⌘↓", "otwórz zaznaczone (folder: wejdź)"),
            ("⌘↑", "folder nadrzędny"),
            ("⌘[  /  ⌘]", "wstecz / dalej"),
            ("⇧⌘O", "wybierz folder…"),
            ("⌘D", "dodaj / usuń folder z ulubionych"),
            ("⌘R", "odśwież"),
        ]),
        g("Pliki i foldery", [
            ("F5  (fn+F5)", "kopiuj do drugiego panelu"),
            ("F6  (fn+F6)", "przenieś do drugiego panelu"),
            ("F2  (fn+F2)", "zmień nazwę zaznaczonego elementu"),
            ("⇧⌘N", "nowy folder"),
            ("⌘⌫", "przenieś do Kosza (z potwierdzeniem)"),
            ("⌘E", "wysuń wolumin aktywnego panelu"),
            ("⌥⌘R", "pokaż w Finderze"),
        ]),
        g("Schowek", [
            ("⌘C  /  ⌥C", "kopiuj zaznaczone pliki do schowka"),
            ("⌘V  /  ⌥V", "wklej pliki do folderu aktywnego panelu"),
            ("⌥⌘C", "kopiuj ścieżkę"),
            ("⌘A", "zaznacz wszystko"),
        ]),
        g("Szukanie i podgląd", [
            ("⌘F", "szukaj w folderze i podfolderach (Esc zamyka)"),
            ("Spacja", "szybki podgląd (Quick Look)"),
            ("⌘I", "panel informacji"),
            ("⇧⌘.", "pokaż / ukryj pliki ukryte"),
        ]),
        g("Karty i przestrzenie", [
            ("⌘T", "nowa karta"),
            ("⌘W", "zamknij kartę (ostatnia karta panelu zamyka okno)"),
            ("⇧⌘]  /  ⇧⌘[", "następna / poprzednia karta"),
            ("⌥⌘S", "zapisz bieżącą przestrzeń roboczą"),
        ]),
        g("Narzędzia", [
            ("⇧⌘R", "zmień nazwy zaznaczonych (zbiorczo)"),
            ("⇧⌘K", "porównaj foldery obu paneli"),
            ("—", "duplikaty: menu Narzędzia → Znajdź duplikaty w tym folderze"),
        ]),
        g("Mysz", [
            ("Przeciągnięcie", "na drugi panel: ten sam wolumin → przeniesienie, inny → kopia"),
            ("⌥ + przeciągnięcie", "zawsze kopia"),
            ("Dwuklik na separatorze", "panele po równo (separator można przeciągać)"),
            ("Prawy klik", "menu kontekstowe; na nagłówku tabeli: widoczność kolumn"),
        ]),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Skróty klawiszowe").font(.title2.bold())
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.title).font(.headline)
                        Divider()
                        ForEach(group.items) { item in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(item.keys)
                                    .font(.system(.body, design: .monospaced))
                                    .frame(width: 190, alignment: .leading)
                                Text(item.text).foregroundStyle(.secondary)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
                Text("Klawisze funkcyjne na klawiaturach MacBooka wymagają przytrzymania fn (lub włączenia „Używaj klawiszy F1, F2 itd. jako standardowych”).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(24)
        }
        .frame(minWidth: 560, minHeight: 480)
    }
}
