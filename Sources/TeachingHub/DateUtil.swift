import Foundation

enum DateUtil {
    static let calendar = Calendar.current

    static func startOfDay(_ d: Date) -> Date { calendar.startOfDay(for: d) }

    static func startOfWeek(_ d: Date, weekStartsOn: Int = 2) -> Date {
        // weekStartsOn: 1=Sun, 2=Mon (matches Calendar.firstWeekday convention)
        var cal = calendar
        cal.firstWeekday = weekStartsOn
        let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: d)
        return cal.date(from: comps) ?? startOfDay(d)
    }

    static func sameDay(_ a: Date, _ b: Date) -> Bool {
        calendar.isDate(a, inSameDayAs: b)
    }

    static func sameMonth(_ a: Date, _ b: Date) -> Bool {
        let ca = calendar.dateComponents([.year, .month], from: a)
        let cb = calendar.dateComponents([.year, .month], from: b)
        return ca.year == cb.year && ca.month == cb.month
    }

    static func formatTime(_ d: Date) -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        return f.string(from: d)
    }

    static func formatDateOnly(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f.string(from: d)
    }

    /// Short date suitable for dense lists — e.g. "Mon 5 Sep".
    static func formatShortDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM"
        return f.string(from: d)
    }
}

extension Entry {
    /// Sort comparator: all-day first (alphabetical), then timed by time, ties by title.
    static func compareForDay(_ a: Entry, _ b: Entry) -> Bool {
        if a.hasTime != b.hasTime { return !a.hasTime }
        if a.hasTime {
            if a.date != b.date { return a.date < b.date }
        }
        return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
    }
}
