import Foundation

/// School year terms and holidays — loaded from `<Teaching>/terms.conf`.
///
/// Example file:
///
///     # VISP 2026-27
///     year: 2026-27
///
///     # term: <name> | <start YYYY-MM-DD> | <end YYYY-MM-DD>
///     term: Autumn 1 | 2026-09-01 | 2026-10-23
///     term: Autumn 2 | 2026-11-02 | 2026-12-18
///
///     # holiday: <YYYY-MM-DD> | <reason>
///     holiday: 2026-10-14 | Inset day
struct TermConfig {
    let yearLabel: String
    let terms: [Term]
    let holidays: [Holiday]
    let sourceURL: URL?

    struct Term: Hashable {
        let name: String
        let start: Date   // inclusive, 00:00 local
        let end: Date     // inclusive, end-of-day local
    }

    struct Holiday: Hashable {
        let date: Date    // 00:00 local
        let reason: String
    }

    static let empty = TermConfig(yearLabel: "", terms: [], holidays: [], sourceURL: nil)

    // MARK: - Teaching-day predicate

    /// True if the given moment falls inside any configured term AND is not a holiday.
    /// Weekends (Sat/Sun) are also treated as non-teaching, since schools don't normally
    /// run on them — timetables are explicitly weekday-based.
    func isTeachingDay(_ moment: Date) -> Bool {
        let cal = Calendar.current
        let day = cal.startOfDay(for: moment)
        let weekday = cal.component(.weekday, from: day)
        if weekday == 1 || weekday == 7 { return false }  // Sunday or Saturday
        if terms.isEmpty { return true }  // no terms configured → everything's fair game
        let inAnyTerm = terms.contains { day >= cal.startOfDay(for: $0.start) && day <= cal.startOfDay(for: $0.end) }
        if !inAnyTerm { return false }
        let isHoliday = holidays.contains { cal.isDate($0.date, inSameDayAs: day) }
        return !isHoliday
    }

    // MARK: - Loading

    static func load(from folderURL: URL) -> TermConfig {
        let url = folderURL.appendingPathComponent("terms.conf")
        guard FileManager.default.fileExists(atPath: url.path),
              let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return .empty
        }
        return parse(contents, sourceURL: url)
    }

    static func parse(_ contents: String, sourceURL: URL? = nil) -> TermConfig {
        var yearLabel = ""
        var terms: [Term] = []
        var holidays: [Holiday] = []

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone.current

        for rawLine in contents.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let colonIdx = line.firstIndex(of: ":") else { continue }
            let key = line[..<colonIdx].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colonIdx)...].trimmingCharacters(in: .whitespaces)
            let parts = value.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }

            switch key {
            case "year":
                yearLabel = value
            case "term":
                // name | start | end
                guard parts.count >= 3,
                      let start = df.date(from: parts[1]),
                      let end = df.date(from: parts[2]) else { continue }
                terms.append(Term(name: parts[0], start: start, end: end))
            case "holiday":
                // date | reason
                guard parts.count >= 1, let date = df.date(from: parts[0]) else { continue }
                let reason = parts.count >= 2 ? parts[1] : ""
                holidays.append(Holiday(date: date, reason: reason))
            default:
                continue
            }
        }

        // Sort terms by start, holidays by date
        return TermConfig(
            yearLabel: yearLabel,
            terms: terms.sorted { $0.start < $1.start },
            holidays: holidays.sorted { $0.date < $1.date },
            sourceURL: sourceURL
        )
    }
}
