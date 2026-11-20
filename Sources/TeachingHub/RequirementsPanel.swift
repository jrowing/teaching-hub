import SwiftUI

struct RequirementsPanel: View {
    @EnvironmentObject var store: EntryStore
    let onEdit: (Entry) -> Void

    var body: some View {
        let weekStart = DateUtil.startOfWeek(store.requirementsWeekAnchor)
        let weekEntries = store.entriesInWeek(store.requirementsWeekAnchor, includeWeekend: true)
            .sorted { (a, b) in
                if !DateUtil.sameDay(a.date, b.date) { return a.date < b.date }
                return Entry.compareForDay(a, b)
            }
        let withReqs = weekEntries.filter { !$0.requirements.isEmpty }
        let totalReqs = withReqs.reduce(0) { $0 + $1.requirements.count }

        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Weekly requirements")
                    .font(.system(size: 14, weight: .medium))
                Spacer()
                Button { store.showRequirementsPanel = false } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // Week nav
            HStack {
                Button { changeWeek(-1) } label: { Image(systemName: "chevron.left") }
                VStack(alignment: .leading) {
                    Text(rangeString(start: weekStart))
                        .font(.system(size: 13))
                    Text("\(weekEntries.count) \(weekEntries.count == 1 ? "session" : "sessions")\(store.filterTag.map { " · tagged \($0)" } ?? "")")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("This week") {
                    store.requirementsWeekAnchor = Date()
                }
                .controlSize(.small)
                Button { changeWeek(1) } label: { Image(systemName: "chevron.right") }
            }
            .padding(12)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))

            Picker("Mode", selection: $store.requirementsMode) {
                Text("Aggregated").tag(EntryStore.RequirementsMode.aggregated)
                Text("Per-session").tag(EntryStore.RequirementsMode.breakdown)
            }
            .pickerStyle(.segmented)
            .padding(12)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if weekEntries.isEmpty {
                        Text("No sessions this week.")
                            .foregroundStyle(.secondary)
                            .padding(40)
                            .frame(maxWidth: .infinity)
                    } else {
                        switch store.requirementsMode {
                        case .aggregated:
                            aggregatedView(weekEntries)
                        case .breakdown:
                            breakdownView(withReqs)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }

            if !weekEntries.isEmpty {
                Divider()
                Text("\(withReqs.count) of \(weekEntries.count) \(weekEntries.count == 1 ? "session has" : "sessions have") requirements · \(totalReqs) item\(totalReqs == 1 ? "" : "s") total")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            }
        }
    }

    private func aggregatedView(_ entries: [Entry]) -> some View {
        let sorted = aggregateRequirements(entries)
        return Group {
            if sorted.isEmpty {
                Text("No `## Requirements` sections found in this week's sessions.")
                    .foregroundStyle(.secondary)
                    .padding(20)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(sorted, id: \.display) { item in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "circle")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Text(item.display)
                                .font(.system(size: 13))
                            Spacer()
                            Text("\(item.sessions.count)×")
                                .font(.system(size: 11))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Color(NSColor.controlBackgroundColor), in: Capsule())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                        Divider()
                    }
                }
            }
        }
    }

    private struct AggregatedItem {
        let display: String
        let sessions: Set<String>
    }

    private func aggregateRequirements(_ entries: [Entry]) -> [AggregatedItem] {
        var buckets: [String: (display: String, sessions: Set<String>)] = [:]
        for e in entries {
            for req in e.requirements {
                let key = req.lowercased().trimmingCharacters(in: .whitespaces)
                if buckets[key] == nil {
                    buckets[key] = (display: req, sessions: [])
                }
                buckets[key]!.sessions.insert(e.id)
            }
        }
        return buckets.values
            .map { AggregatedItem(display: $0.display, sessions: $0.sessions) }
            .sorted { a, b in
                if a.sessions.count != b.sessions.count { return a.sessions.count > b.sessions.count }
                return a.display.localizedCaseInsensitiveCompare(b.display) == .orderedAscending
            }
    }

    private func breakdownView(_ entries: [Entry]) -> some View {
        Group {
            if entries.isEmpty {
                Text("No sessions this week have requirements listed.")
                    .foregroundStyle(.secondary)
                    .padding(20)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(entries, id: \.id) { e in
                        Button { onEdit(e) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(dayLabel(e.date)) · \(e.hasTime ? DateUtil.formatTime(e.date) : "all day")")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)
                                Text(e.title)
                                    .font(.system(size: 13, weight: .medium))
                                ForEach(e.requirements, id: \.self) { r in
                                    HStack(alignment: .top, spacing: 6) {
                                        Text("•").foregroundStyle(.secondary)
                                        Text(r).font(.system(size: 12))
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.bottom, 8)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func rangeString(start: Date) -> String {
        let cal = Calendar.current
        let end = cal.date(byAdding: .day, value: 6, to: start)!
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return "\(f.string(from: start)) – \(f.string(from: end))"
    }

    private func dayLabel(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d"
        return f.string(from: d)
    }

    private func changeWeek(_ delta: Int) {
        if let d = Calendar.current.date(byAdding: .day, value: delta * 7, to: store.requirementsWeekAnchor) {
            store.requirementsWeekAnchor = d
        }
    }
}
