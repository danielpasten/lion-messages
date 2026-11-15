import Foundation

/// Lion-era date strings.
enum LionDateFormat {
    private static func formatter(_ template: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.setLocalizedDateFormatFromTemplate(template)
        return f
    }

    /// Lucida Grande has no narrow no-break space (used by newer ICU before AM/PM).
    private static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    private static let time = formatter("h:mm a")
    private static let weekday = formatter("EEEE")
    private static let shortDate = formatter("M/d/yy")
    private static let mediumDate = formatter("MMM d, yyyy")

    /// Sidebar dates, as Mail on Lion showed them: "9:41 AM", "Yesterday", "Monday", "11/3/26".
    static func sidebar(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "" }
        let cal = Calendar.current
        if cal.isDate(date, inSameDayAs: now) { return clean(time.string(from: date)) }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        if let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: now)).day,
           days < 7, days > 0 {
            return weekday.string(from: date)
        }
        return shortDate.string(from: date)
    }

    static func transcriptTime(_ date: Date) -> String { clean(time.string(from: date)) }

    /// Transcript separators: "Today 9:41 AM", "Yesterday 6:02 PM", "Monday 3:15 PM", "Nov 3, 2026 10:00 AM".
    static func transcript(_ date: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        let t = clean(time.string(from: date))
        if cal.isDate(date, inSameDayAs: now) { return "Today \(t)" }
        if cal.isDateInYesterday(date) { return "Yesterday \(t)" }
        if let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: now)).day,
           days < 7, days > 0 {
            return "\(weekday.string(from: date)) \(t)"
        }
        return "\(clean(mediumDate.string(from: date))) \(t)"
    }
}
