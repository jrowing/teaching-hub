import SwiftUI
import AppKit

// MARK: - Serialising & inferring timetables

extension ClassConfig {
    /// Render this timetable back into the `.conf` text format (pipe form, so room names can contain spaces).
    static func serialize(name: String, periods: [Period]) -> String {
        var lines: [String] = []
        lines.append("name: \(name)")
        lines.append("")
        lines.append("# period: <day> | <start> | <end> | <room>")
        let sorted = periods.sorted {
            $0.day.rawValue != $1.day.rawValue ? $0.day.rawValue < $1.day.rawValue : $0.startMinutes < $1.startMinutes
        }
        for p in sorted {
            var line = "period: \(p.day.shortName.lowercased()) | \(formatTime(p.startMinutes)) | \(formatTime(p.endMinutes))"
            if let room = p.room, !room.isEmpty { line += " | \(room)" }
            lines.append(line)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Write `<root>/classes/<slug>.conf`, creating the folder if needed. Returns the file URL.
    @discardableResult
    static func write(slug: String, name: String, periods: [Period], root: URL) throws -> URL {
        let dir = root.appendingPathComponent("classes", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(slug).conf")
        try serialize(name: name, periods: periods).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Guess a weekly timetable from existing lessons for `slug`: any weekday + start time that
    /// recurs in at least two lessons becomes a period. Lessons without a time-of-day are ignored.
    static func inferPeriods(from entries: [Entry], slug: String) -> [Period] {
        struct Key: Hashable { let day: Int; let start: Int }
        let cal = Calendar.current
        var counts: [Key: Int] = [:]
        var durations: [Key: [Int]] = [:]
        for e in entries where e.classSlug == slug && e.hasTime {
            let comps = cal.dateComponents([.weekday, .hour, .minute], from: e.date)
            guard let wd = comps.weekday, let h = comps.hour, let m = comps.minute else { continue }
            let key = Key(day: wd, start: h * 60 + m)
            counts[key, default: 0] += 1
            if let end = e.endDate {
                let mins = Int(end.timeIntervalSince(e.date) / 60)
                if mins > 0 { durations[key, default: []].append(mins) }
            }
        }
        var result: [Period] = []
        for (key, n) in counts where n >= 2 {
            guard let day = Period.Weekday(rawValue: key.day) else { continue }
            // Most common duration, defaulting to one hour.
            let ds = durations[key] ?? []
            let dur = Dictionary(grouping: ds, by: { $0 }).max { $0.value.count < $1.value.count }?.key ?? 60
            let end = min(key.start + dur, 24 * 60 - 1)
            result.append(Period(day: day, startMinutes: key.start, endMinutes: end, room: nil))
        }
        return result.sorted {
            $0.day.rawValue != $1.day.rawValue ? $0.day.rawValue < $1.day.rawValue : $0.startMinutes < $1.startMinutes
        }
    }

    /// Parse "HH:mm" (also accepts "H:mm"). Returns minutes since midnight.
    static func parseTimeField(_ s: String) -> Int? {
        let parts = s.trimmingCharacters(in: .whitespaces).split(separator: ":").map(String.init)
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
              (0..<24).contains(h), (0..<60).contains(m) else { return nil }
        return h * 60 + m
    }
}

// MARK: - Editor sheet

/// What the editor is editing: an existing class or a new one for a given slug.
struct ClassEditorTarget: Identifiable {
    let slug: String
    let existing: ClassConfig?
    var id: String { slug }
}

struct ClassEditorSheet: View {
    let target: ClassEditorTarget
    @EnvironmentObject var store: EntryStore
    @Environment(\.dismiss) private var dismiss

    private struct Row: Identifiable {
        let id = UUID()
        var day: ClassConfig.Period.Weekday = .mon
        var start: String = "09:00"
        var end: String = "10:00"
        var room: String = ""
    }

    @State private var name: String = ""
    @State private var rows: [Row] = []
    @State private var errorText: String?
    @State private var didLoad = false

    private let weekdays: [ClassConfig.Period.Weekday] = [.mon, .tue, .wed, .thu, .fri, .sat, .sun]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(target.existing == nil ? "New class timetable" : "Edit timetable")
                        .font(.title3).fontWeight(.semibold)
                    Text("classes/\(target.slug).conf")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(20)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Class name").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        TextField("e.g. Year 10 Science", text: $name)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Weekly periods").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                fillFromHistory()
                            } label: {
                                Label("Fill from lesson history", systemImage: "wand.and.stars")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.blue)
                            .help("Looks at this class's existing lessons and adds any weekday + start time that repeats")
                        }

                        if rows.isEmpty {
                            Text("No periods yet. Add one, or fill them in from the lessons you already have.")
                                .font(.system(size: 12)).foregroundStyle(.tertiary)
                        }

                        ForEach($rows) { $row in
                            HStack(spacing: 8) {
                                Picker("", selection: $row.day) {
                                    ForEach(weekdays, id: \.self) { Text($0.shortName).tag($0) }
                                }
                                .labelsHidden()
                                .frame(width: 70)
                                TextField("09:30", text: $row.start)
                                    .textFieldStyle(.roundedBorder).frame(width: 64)
                                Text("–")
                                TextField("10:30", text: $row.end)
                                    .textFieldStyle(.roundedBorder).frame(width: 64)
                                TextField("Room (optional)", text: $row.room)
                                    .textFieldStyle(.roundedBorder)
                                Button {
                                    rows.removeAll { $0.id == row.id }
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                            }
                        }

                        Button {
                            rows.append(Row())
                        } label: {
                            Label("Add period", systemImage: "plus.circle").font(.system(size: 12))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.blue)
                    }

                    if let errorText {
                        Text(errorText)
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.red.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }

                    Text("Times are 24-hour (13:10). Saving rewrites the .conf file; any comments in it are replaced.")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                .padding(20)
            }
        }
        .frame(width: 520, height: 460)
        .onAppear(perform: load)
    }

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        if let cfg = target.existing {
            name = cfg.name
            rows = cfg.periods.map {
                Row(day: $0.day,
                    start: ClassConfig.formatTime($0.startMinutes),
                    end: ClassConfig.formatTime($0.endMinutes),
                    room: $0.room ?? "")
            }
        } else {
            name = target.slug
                .replacingOccurrences(of: "-", with: " ")
                .capitalized
        }
    }

    private func fillFromHistory() {
        let inferred = ClassConfig.inferPeriods(from: store.entries, slug: target.slug)
        guard !inferred.isEmpty else {
            errorText = "Couldn't find a repeating weekday + time in this class's lessons (need at least two lessons with a start time at the same slot)."
            return
        }
        errorText = nil
        rows = inferred.map {
            Row(day: $0.day,
                start: ClassConfig.formatTime($0.startMinutes),
                end: ClassConfig.formatTime($0.endMinutes),
                room: "")
        }
    }

    private func save() {
        guard let root = store.folderURL else {
            errorText = "No Teaching folder is open."
            return
        }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { errorText = "Give the class a name."; return }

        var periods: [ClassConfig.Period] = []
        for (i, r) in rows.enumerated() {
            guard let s = ClassConfig.parseTimeField(r.start), let e = ClassConfig.parseTimeField(r.end) else {
                errorText = "Row \(i + 1): times must look like 09:30."
                return
            }
            guard e > s else { errorText = "Row \(i + 1): end time must be after start time."; return }
            let room = r.room.trimmingCharacters(in: .whitespaces)
            periods.append(.init(day: r.day, startMinutes: s, endMinutes: e, room: room.isEmpty ? nil : room))
        }
        do {
            try ClassConfig.write(slug: target.slug, name: trimmedName, periods: periods, root: root)
            store.reload()
            dismiss()
        } catch {
            errorText = "Couldn't save: \(error.localizedDescription)"
        }
    }
}
