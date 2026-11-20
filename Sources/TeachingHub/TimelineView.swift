import SwiftUI

struct TimelineView: View {
    @EnvironmentObject var store: EntryStore
    let onEdit: (Entry) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if let tag = store.filterTag {
                    HStack(spacing: 8) {
                        Text("Tagged")
                            .font(.title2)
                            .fontWeight(.semibold)
                        TagPill(tag: tag, active: true)
                        Spacer()
                        Button("Clear filter") { store.filterTag = nil }
                    }
                } else {
                    Text("All entries")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Spacer()
                }
            }
            .padding(16)

            Divider()

            ScrollView {
                let filtered = store.entries
                    .filter { !$0.isParked }
                    .filter { store.filterTag == nil || $0.tags.contains(store.filterTag!) }
                    .sorted { (a, b) in
                        if !DateUtil.sameDay(a.date, b.date) {
                            return a.date < b.date
                        }
                        return Entry.compareForDay(a, b)
                    }
                let grouped = Dictionary(grouping: filtered) { e -> String in
                    let f = DateFormatter()
                    f.dateFormat = "yyyy-MM"
                    return f.string(from: e.date)
                }
                let monthKeys = grouped.keys.sorted()

                if filtered.isEmpty {
                    Text(store.filterTag == nil ? "No entries yet" : "No entries tagged \(store.filterTag!)")
                        .foregroundStyle(.secondary)
                        .padding(40)
                        .frame(maxWidth: .infinity)
                } else {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(monthKeys, id: \.self) { key in
                            Section(header: monthHeader(key)) {
                                ForEach(grouped[key]!, id: \.id) { entry in
                                    TimelineRow(entry: entry, onEdit: onEdit)
                                        .lessonDraggable(entry)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
            }
        }
    }

    private func monthHeader(_ key: String) -> some View {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM"
        let date = f.date(from: key) ?? Date()
        let display = DateFormatter()
        display.dateFormat = "MMMM yyyy"
        return HStack {
            Text(display.string(from: date).uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.vertical, 6)
            Spacer()
        }
        .background(Color(NSColor.windowBackgroundColor))
    }
}

private struct TimelineRow: View {
    let entry: Entry
    let onEdit: (Entry) -> Void
    @EnvironmentObject var store: EntryStore

    var body: some View {
        Button { onEdit(entry) } label: {
            HStack(alignment: .top, spacing: 12) {
                // Date column
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(Calendar.current.component(.day, from: entry.date))")
                        .font(.system(size: 18, weight: .semibold))
                    Text(weekdayShort)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if entry.hasTime {
                        Text(timeStr)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 80, alignment: .trailing)

                // Rail
                ZStack(alignment: .top) {
                    Rectangle()
                        .fill(Color(NSColor.separatorColor))
                        .frame(width: 2)
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 8, height: 8)
                        .padding(.top, 6)
                }
                .frame(width: 12)
                .frame(maxHeight: .infinity)

                // Content
                VStack(alignment: .leading, spacing: 6) {
                    Text(entry.title)
                        .font(.headline)
                    if !entry.tags.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(entry.tags, id: \.self) { t in
                                Button {
                                    store.filterTag = (store.filterTag == t) ? nil : t
                                } label: {
                                    TagPill(tag: t, active: store.filterTag == t)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    if !entry.body.isEmpty {
                        MarkdownView(source: entry.body)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 12)
            }
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .background(Color.clear)
    }

    private var weekdayShort: String {
        let f = DateFormatter(); f.dateFormat = "EEE"
        return f.string(from: entry.date)
    }
    private var timeStr: String {
        DateUtil.formatTime(entry.date)
    }
}
