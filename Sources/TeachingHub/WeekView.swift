import SwiftUI
import UniformTypeIdentifiers

struct WeekView: View {
    @EnvironmentObject var store: EntryStore
    /// Index of the day column currently receiving a drag hover, for the drop ghost.
    @State private var targetedDay: Int? = nil
    let onEdit: (Entry) -> Void
    let onCreate: (Date) -> Void

    private let startHour: Int = 7
    private let endHour: Int = 17
    private let hourHeight: CGFloat = 56

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            dayHeaders
            Divider()
            allDayRow
            ScrollView(.vertical) {
                gridArea
            }
        }
    }

    private var header: some View {
        HStack {
            Text(weekTitle)
                .font(.title2)
                .fontWeight(.semibold)
            Spacer()
            Button { changeWeek(-1) } label: { Image(systemName: "chevron.left") }
            Button("This week") {
                store.weekAnchor = Date()
                store.selectedDate = DateUtil.startOfDay(Date())
            }
            Button { changeWeek(1) } label: { Image(systemName: "chevron.right") }
        }
        .padding(16)
    }

    private var dayHeaders: some View {
        HStack(spacing: 0) {
            Text("")
                .frame(width: 56)
            ForEach(0..<5, id: \.self) { i in
                let day = dayDate(i)
                let isToday = Calendar.current.isDateInToday(day)
                VStack(spacing: 2) {
                    Text(weekdayShort(day))
                        .font(.caption)
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)
                    Text("\(Calendar.current.component(.day, from: day))")
                        .font(.title2)
                        .fontWeight(isToday ? .bold : .regular)
                        .foregroundColor(isToday ? .white : .primary)
                        .frame(width: 28, height: 28)
                        .background(isToday ? Color.orange : Color.clear, in: Circle())
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
                .onTapGesture {
                    store.selectedDate = DateUtil.startOfDay(day)
                }
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var allDayRow: some View {
        let allDays: [[Entry]] = (0..<5).map { i in
            store.entries(on: dayDate(i)).filter { !$0.hasTime }
        }
        let hasAny = allDays.contains { !$0.isEmpty }
        return Group {
            if hasAny {
                HStack(spacing: 0) {
                    Text("All-day")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .trailing)
                        .padding(.trailing, 8)
                    ForEach(0..<5, id: \.self) { i in
                        VStack(spacing: 2) {
                            ForEach(allDays[i], id: \.id) { e in
                                Button {
                                    onEdit(e)
                                } label: {
                                    HStack {
                                        Text(e.title).lineLimit(1).font(.system(size: 11))
                                        Spacer()
                                    }
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                }
                                .buttonStyle(.plain)
                                .background(
                                    e.tags.first.map { TagColor.background(for: $0) } ?? Color.accentColor.opacity(0.18)
                                )
                                .foregroundColor(
                                    e.tags.first.map { TagColor.foreground(for: $0) } ?? Color.accentColor
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(4)
                    }
                }
                .padding(.vertical, 4)
                .background(Color(NSColor.controlBackgroundColor))
                Divider()
            }
        }
    }

    private var gridArea: some View {
        let totalHours = endHour - startHour
        return ZStack(alignment: .topLeading) {
            // Hour rows + gutter
            VStack(spacing: 0) {
                ForEach(0..<totalHours, id: \.self) { h in
                    HStack(spacing: 0) {
                        Text(formatHourLabel(startHour + h))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(width: 56, alignment: .trailing)
                            .padding(.trailing, 8)
                            .padding(.top, 2)
                        ForEach(0..<5, id: \.self) { _ in
                            Rectangle()
                                .fill(Color.clear)
                                .frame(maxWidth: .infinity)
                                .frame(height: hourHeight)
                                .overlay(
                                    Rectangle()
                                        .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
                                )
                        }
                    }
                    .frame(height: hourHeight)
                }
            }

            // Event overlays per day
            GeometryReader { geo in
                let dayWidth = (geo.size.width - 56) / 5
                ZStack(alignment: .topLeading) {
                    ForEach(0..<5, id: \.self) { i in
                        dayOverlay(index: i, dayWidth: dayWidth, totalHours: totalHours)
                    }
                }
            }
            .frame(height: CGFloat(totalHours) * hourHeight)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func dayOverlay(index: Int, dayWidth: CGFloat, totalHours: Int) -> some View {
        let day = dayDate(index)
        let timed = store.entries(on: day).filter { $0.hasTime && !$0.isParked }
        let layout = computeLayout(timed)
        let dayLeft: CGFloat = 56 + CGFloat(index) * dayWidth

        // Day-column drop zone. The drop and visual modifiers go BEFORE
        // `.position()` because `.position()` returns a parent-filling view —
        // attaching `.dropDestination` after it makes the drop zone cover the
        // entire 5-day area, so Friday's handler swallows every drop.
        Rectangle()
            .fill(targetedDay == index ? Color.accentColor.opacity(0.08) : Color.clear)
            .overlay(
                Rectangle()
                    .stroke(Color.accentColor, lineWidth: targetedDay == index ? 2 : 0)
            )
            .frame(width: dayWidth, height: CGFloat(totalHours) * hourHeight)
            .onDrop(of: [.plainText, .text, .utf8PlainText],
                    isTargeted: Binding(
                        get: { targetedDay == index },
                        set: { hovering in
                            targetedDay = hovering ? index : (targetedDay == index ? nil : targetedDay)
                        }
                    )) { providers in
                LessonDrag.resolve(providers: providers, store: store) { entry in
                    try? store.scheduleEntry(entry, onto: day)
                }
            }
            .position(x: dayLeft + dayWidth / 2, y: CGFloat(totalHours) * hourHeight / 2)

        ForEach(0..<layout.count, id: \.self) { idx in
            let p = layout[idx]
            EventBlock(entry: p.entry)
                .frame(width: max(20, dayWidth * p.width - 4),
                       height: max(18, p.height - 2))
                .onTapGesture { onEdit(p.entry) }
                .lessonDraggable(p.entry)
                .onDrop(of: [.plainText, .text, .utf8PlainText], isTargeted: nil) { providers in
                    LessonDrag.resolve(providers: providers, store: store) { dragged in
                        guard dragged.id != p.entry.id else { return }
                        let option = NSEvent.modifierFlags.contains(.option)
                        if option {
                            try? store.insertByCascade(dragged, atSlotOf: p.entry)
                        } else {
                            try? store.swapEntries(dragged, p.entry)
                        }
                    }
                }
                // `.position` MUST be last — it returns a parent-filling view,
                // which would make the modifiers above apply to the whole area.
                .position(
                    x: dayLeft + dayWidth * (p.left + p.width / 2),
                    y: p.top + max(18, p.height - 2) / 2
                )
        }

        nowLineIfToday(day: day, dayWidth: dayWidth, dayLeft: dayLeft, totalHours: totalHours)
    }

    @ViewBuilder
    private func nowLineIfToday(day: Date, dayWidth: CGFloat, dayLeft: CGFloat, totalHours: Int) -> some View {
        if Calendar.current.isDateInToday(day) {
            let now = Date()
            let comps = Calendar.current.dateComponents([.hour, .minute], from: now)
            let mins = (comps.hour ?? 0) * 60 + (comps.minute ?? 0) - startHour * 60
            if mins >= 0 && mins <= totalHours * 60 {
                let y = CGFloat(mins) / 60.0 * hourHeight
                Rectangle()
                    .fill(Color.red)
                    .frame(width: dayWidth, height: 2)
                    .position(x: dayLeft + dayWidth / 2, y: y)
            }
        }
    }

    // MARK: - Layout

    private struct PlacedEvent {
        let entry: Entry
        let top: CGFloat
        let height: CGFloat
        let left: CGFloat   // 0..1
        let width: CGFloat  // 0..1
    }

    private func computeLayout(_ entries: [Entry]) -> [PlacedEvent] {
        let cal = Calendar.current
        let startMin = startHour * 60
        let endMin = endHour * 60

        struct Item { let entry: Entry; let s: Int; let e: Int }
        var items: [Item] = []
        for entry in entries {
            let comps = cal.dateComponents([.hour, .minute], from: entry.date)
            let sMin = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
            var eMin: Int
            if let endDate = entry.endDate {
                let sameDay = cal.isDate(entry.date, inSameDayAs: endDate)
                if sameDay {
                    let endComps = cal.dateComponents([.hour, .minute], from: endDate)
                    eMin = (endComps.hour ?? 0) * 60 + (endComps.minute ?? 0)
                } else {
                    eMin = 24 * 60
                }
            } else {
                eMin = sMin + 30
            }
            let cs = max(sMin, startMin)
            let ce = min(eMin, endMin)
            if ce > cs {
                items.append(Item(entry: entry, s: cs, e: ce))
            }
        }
        items.sort { ($0.s, -$0.e) < ($1.s, -$1.e) }

        // Group overlapping events into columns
        struct Group { var items: [(item: Item, col: Int)] = []; var cols: Int = 0 }
        var groups: [Group] = []
        var current = Group()
        var currentEnd = Int.min
        for item in items {
            if item.s >= currentEnd {
                if !current.items.isEmpty { groups.append(current) }
                current = Group()
            }
            let used = Set(current.items
                .filter { $0.item.e > item.s }
                .map { $0.col })
            var col = 0
            while used.contains(col) { col += 1 }
            current.items.append((item, col))
            current.cols = max(current.cols, col + 1)
            currentEnd = max(currentEnd, item.e)
        }
        if !current.items.isEmpty { groups.append(current) }

        var out: [PlacedEvent] = []
        for g in groups {
            for placed in g.items {
                let top = CGFloat(placed.item.s - startHour * 60) / 60.0 * hourHeight
                let height = CGFloat(placed.item.e - placed.item.s) / 60.0 * hourHeight
                let colWidth = 1.0 / CGFloat(g.cols)
                out.append(PlacedEvent(
                    entry: placed.item.entry,
                    top: top, height: height,
                    left: CGFloat(placed.col) * colWidth,
                    width: colWidth
                ))
            }
        }
        return out
    }

    // MARK: - Helpers

    private var weekTitle: String {
        let start = DateUtil.startOfWeek(store.weekAnchor)
        let end = Calendar.current.date(byAdding: .day, value: 4, to: start)!
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        let yf = DateFormatter(); yf.dateFormat = "yyyy"
        return "\(f.string(from: start)) – \(f.string(from: end)), \(yf.string(from: end))"
    }

    private func dayDate(_ index: Int) -> Date {
        let start = DateUtil.startOfWeek(store.weekAnchor)
        return Calendar.current.date(byAdding: .day, value: index, to: start)!
    }

    private func changeWeek(_ delta: Int) {
        if let d = Calendar.current.date(byAdding: .day, value: delta * 7, to: store.weekAnchor) {
            store.weekAnchor = d
        }
    }

    private func weekdayShort(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return f.string(from: d)
    }

    private func formatHourLabel(_ h: Int) -> String {
        if h == 0 { return "12am" }
        if h == 12 { return "12pm" }
        return h < 12 ? "\(h)am" : "\(h - 12)pm"
    }
}

private struct EventBlock: View {
    let entry: Entry
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let firstTag = entry.tags.first
        let dark = scheme == .dark
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 2) {
                Text(timeStr)
                    .font(.system(size: 10))
                    .opacity(0.85)
                Text(entry.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                // Body preview — only when the card is tall enough that the
                // title won't push it off the bottom. Height 55 ≈ an 80-min
                // lesson at 56 px/hr is 75 px, which fits a two-line preview.
                if geo.size.height >= 55, !bodyPreview.isEmpty {
                    Text(bodyPreview)
                        .font(.system(size: 10))
                        .opacity(0.75)
                        .lineLimit(bodyPreviewLineLimit(for: geo.size.height))
                        .multilineTextAlignment(.leading)
                        .padding(.top, 1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                firstTag.map { TagColor.background(for: $0, dark: dark) } ?? Color.accentColor.opacity(0.2)
            )
            .foregroundColor(
                firstTag.map { TagColor.foreground(for: $0, dark: dark) } ?? Color.accentColor
            )
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }

    private var timeStr: String {
        let s = DateUtil.formatTime(entry.date)
        if let end = entry.endDate {
            return "\(s) – \(DateUtil.formatTime(end))"
        }
        return s
    }

    /// Flatten the markdown body into a compact preview: drop heading lines,
    /// code fences, HTML-ish tags, bold/italic markers, list bullets, and
    /// the parenthetical syllabus-code trailer that appears on the opening
    /// bold line of most lessons. Joins the first few surviving lines with " · ".
    private var bodyPreview: String {
        var kept: [String] = []
        var inFence = false
        for raw in entry.body.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { inFence.toggle(); continue }
            if inFence { continue }
            if line.isEmpty { continue }
            if line.hasPrefix("#") { continue }           // drop markdown headings
            // strip common markers
            line = line.replacingOccurrences(of: "**", with: "")
            line = line.replacingOccurrences(of: "__", with: "")
            while line.hasPrefix("-") || line.hasPrefix("*") || line.hasPrefix(">") {
                line.removeFirst()
                line = line.trimmingCharacters(in: .whitespaces)
            }
            // The opening bold title line usually looks like
            // "Plant nutrition (B6.1.1–B6.1.3)". The title's already shown above
            // the preview, so prefer to skip it when it echoes the title.
            let titleStripped = entry.title.lowercased()
            let candidateStripped = line.replacingOccurrences(of: #"\s*\([^)]*\)\s*$"#, with: "", options: .regularExpression).lowercased()
            if candidateStripped == titleStripped { continue }
            kept.append(line)
            if kept.count >= 4 { break }
        }
        return kept.joined(separator: " · ")
    }

    private func bodyPreviewLineLimit(for height: CGFloat) -> Int {
        if height >= 110 { return 4 }
        if height >= 85  { return 3 }
        return 2
    }
}
