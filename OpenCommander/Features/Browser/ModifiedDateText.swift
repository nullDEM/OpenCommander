import Foundation

/// Zwięzły zapis daty modyfikacji w tabeli plików i oknach dialogowych.
enum ModifiedDateText {
    private static let timeStyle = Date.FormatStyle.dateTime.hour().minute()
    private static let sameYearStyle = Date.FormatStyle.dateTime.day().month(.abbreviated).hour().minute()
    private static let otherYearStyle = Date.FormatStyle.dateTime.day().month(.abbreviated).year()

    /// Dziś / wczoraj z godziną, w tym roku „14 paź, 03:12”, wcześniej „1 mar 2025”; brak daty to „—”.
    static func string(for date: Date?) -> String {
        guard let date else { return "—" }
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Dziś, \(date.formatted(timeStyle))" }
        if cal.isDateInYesterday(date) { return "Wczoraj, \(date.formatted(timeStyle))" }
        if cal.isDate(date, equalTo: .now, toGranularity: .year) { return date.formatted(sameYearStyle) }
        return date.formatted(otherYearStyle)
    }
}
