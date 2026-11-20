import Foundation

/// Timetable for a single class — loaded from a `.conf` file at
/// `<TeachingFolder>/classes/<slug>.conf`.
///
/// File format is deliberately simple so teachers can edit it in any text editor:
///
///     # Year 9 Science timetable
///     name: Year 9 Science
///
///     # One period per line: <day> <start>-<end> [room]
///     period: mon 09:30-10:30 room-203
///     period: wed 11:10-12:30 room-203
///     period: fri 13:10-14:30 room-lab-2
///
/// Lines starting with `#` are comments; blank lines are ignored.
/// Day codes: mon, tue, wed, thu, fri, sat, sun.
struct ClassConfig: Identifiable, Hashable {
    let slug: String           // filename stem, e.g. "year-9" — matches the top-level folder name for lessons of this class
    let name: String           // human-readable name
    let periods: [Period]      // ordered by day-of-week + start-time
    let students: Int?         // optional class size (used to scale lab requirements)
    let sourceURL: URL         // where this was loaded from

    var id: String { slug }

    struct Period: Hashable {
        /// Monday = 2, Tuesday = 3 … to match `Calendar.component(.weekday, …)`
        /// (Sunday = 1 in Apple's weekday numbering).
        enum Weekday: Int, CaseIterable {
            case sun = 1, mon = 2, tue = 3, wed = 4, thu = 5, fri = 6, sat = 7

            static func parse(_ s: String) -> Weekday? {
                switch s.lowercased() {
                case "sun", "sunday": return .sun
                case "mon", "monday": return .mon
                case "tue", "tues", "tuesday": return .tue
                case "wed", "weds", "wednesday": return .wed
                case "thu", "thur", "thurs", "thursday": return .thu
                case "fri", "friday": return .fri
                case "sat", "saturday": return .sat
                default: return nil
                }
            }

            var shortName: String {
                switch self {
                case .sun: return "Sun"; case .mon: return "Mon"
                case .tue: return "Tue"; case .wed: return "Wed"
                case .thu: return "Thu"; case .fri: return "Fri"
                case .sat: return "Sat"
                }
            }
        }

        let day: Weekday
        let startMinutes: Int   // minutes since midnight (e.g. 09:30 → 570)
        let endMinutes: Int
        let room: String?

        var startTime: String { ClassConfig.formatTime(startMinutes) }
        var endTime: String { ClassConfig.formatTime(endMinutes) }

        var description: String {
            let r = room.map { " · \($0)" } ?? ""
            return "\(day.shortName) \(startTime)–\(endTime)\(r)"
        }
    }

    // MARK: - Loading

    /// Load every `.conf` file inside `<folderURL>/classes/`.
    /// Silently skips files that fail to parse — we don't want a typo in one
    /// class config to block the whole app from loading.
    static func loadAll(from folderURL: URL) -> [ClassConfig] {
        let classesDir = folderURL.appendingPathComponent("classes", isDirectory: true)
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: classesDir.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }
        guard let items = try? fm.contentsOfDirectory(at: classesDir, includingPropertiesForKeys: nil) else {
            return []
        }
        var results: [ClassConfig] = []
        for url in items {
            guard url.pathExtension.lowercased() == "conf" else { continue }
            if let config = try? parse(url: url) {
                results.append(config)
            }
        }
        return results.sorted { $0.slug < $1.slug }
    }

    static func parse(url: URL) throws -> ClassConfig {
        let contents = try String(contentsOf: url, encoding: .utf8)
        let slug = url.deletingPathExtension().lastPathComponent
        var name: String = slug
        var periods: [Period] = []
        var students: Int? = nil

        for rawLine in contents.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let colonIdx = line.firstIndex(of: ":") else { continue }
            let key = line[..<colonIdx].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colonIdx)...].trimmingCharacters(in: .whitespaces)

            switch key {
            case "name":
                name = value
            case "students", "class_size", "roll":
                students = Int(value)
            case "period":
                if let p = parsePeriod(value) { periods.append(p) }
            default:
                continue  // ignore unknown keys so we can add fields later without breaking old configs
            }
        }

        let sorted = periods.sorted { a, b in
            if a.day.rawValue != b.day.rawValue { return a.day.rawValue < b.day.rawValue }
            return a.startMinutes < b.startMinutes
        }
        return ClassConfig(slug: slug, name: name, periods: sorted, students: students, sourceURL: url)
    }

    /// Parse any of:
    ///   mon 09:30-10:30 room-203
    ///   wed 11:10-12:30
    ///   mon | 09:30 | 10:30 | room-203
    ///   thu | 11:10 | 12:30 | Maths Room
    /// The pipe form is forgiving about whitespace and allows room names
    /// with spaces. The space form keeps backward compatibility.
    private static func parsePeriod(_ s: String) -> Period? {
        // Pipe-separated: "mon | start | end [ | room ]"
        if s.contains("|") {
            let parts = s.split(separator: "|", omittingEmptySubsequences: false)
                         .map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 3 else { return nil }
            guard let day = Period.Weekday.parse(parts[0]) else { return nil }
            guard let start = parseHHMM(parts[1]), let end = parseHHMM(parts[2]) else { return nil }
            guard end > start else { return nil }
            var room: String? = nil
            if parts.count >= 4 {
                let candidate = parts[3...].joined(separator: " | ").trimmingCharacters(in: .whitespaces)
                room = candidate.isEmpty ? nil : candidate
            }
            return Period(day: day, startMinutes: start, endMinutes: end, room: room)
        }

        // Space-separated legacy form: "mon 09:30-10:30 room-203"
        let parts = s.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2 else { return nil }
        guard let day = Period.Weekday.parse(parts[0]) else { return nil }

        let timeSpan = parts[1]
        let timeParts = timeSpan.split(separator: "-", omittingEmptySubsequences: true).map(String.init)
        guard timeParts.count == 2 else { return nil }
        guard let start = parseHHMM(timeParts[0]), let end = parseHHMM(timeParts[1]) else { return nil }
        guard end > start else { return nil }

        let room = parts.count >= 3 ? parts[2...].joined(separator: " ") : nil
        return Period(day: day, startMinutes: start, endMinutes: end, room: room)
    }

    private static func parseHHMM(_ s: String) -> Int? {
        let parts = s.split(separator: ":").map(String.init)
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        guard (0..<24).contains(h), (0..<60).contains(m) else { return nil }
        return h * 60 + m
    }

    static func formatTime(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    // MARK: - Slot queries

    /// The next teaching slot for this class on or after the given moment.
    /// When `terms` is provided, skips holidays and anything outside configured term dates.
    /// Searches up to 180 days ahead (handles jumping a full summer break).
    func nextSlot(onOrAfter moment: Date, terms: TermConfig = .empty) -> SlotMatch? {
        guard !periods.isEmpty else { return nil }
        let cal = Calendar.current
        for dayOffset in 0..<180 {
            guard let probeDay = cal.date(byAdding: .day, value: dayOffset, to: cal.startOfDay(for: moment)) else { continue }
            // Honor term/holiday constraints when configured
            if !terms.isTeachingDay(probeDay) { continue }
            let weekday = cal.component(.weekday, from: probeDay)
            guard let dayEnum = Period.Weekday(rawValue: weekday) else { continue }
            let periodsThatDay = periods.filter { $0.day == dayEnum }
                .sorted { $0.startMinutes < $1.startMinutes }
            for period in periodsThatDay {
                let slotStart = cal.date(byAdding: .minute, value: period.startMinutes, to: probeDay)!
                if slotStart >= moment {
                    let slotEnd = cal.date(byAdding: .minute, value: period.endMinutes, to: probeDay)!
                    return SlotMatch(start: slotStart, end: slotEnd, period: period)
                }
            }
        }
        return nil
    }

    /// The previous teaching slot for this class strictly before the given moment.
    /// Honors term/holiday constraints like `nextSlot`.
    func previousSlot(before moment: Date, terms: TermConfig = .empty) -> SlotMatch? {
        guard !periods.isEmpty else { return nil }
        let cal = Calendar.current
        for dayOffset in 0..<180 {
            guard let probeDay = cal.date(byAdding: .day, value: -dayOffset, to: cal.startOfDay(for: moment)) else { continue }
            if !terms.isTeachingDay(probeDay) { continue }
            let weekday = cal.component(.weekday, from: probeDay)
            guard let dayEnum = Period.Weekday(rawValue: weekday) else { continue }
            let periodsThatDay = periods.filter { $0.day == dayEnum }
                .sorted { $0.startMinutes > $1.startMinutes }  // latest first
            for period in periodsThatDay {
                let slotStart = cal.date(byAdding: .minute, value: period.startMinutes, to: probeDay)!
                if slotStart < moment {
                    let slotEnd = cal.date(byAdding: .minute, value: period.endMinutes, to: probeDay)!
                    return SlotMatch(start: slotStart, end: slotEnd, period: period)
                }
            }
        }
        return nil
    }

    struct SlotMatch: Hashable {
        let start: Date
        let end: Date
        let period: Period
    }
}
