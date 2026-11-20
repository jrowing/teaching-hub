import SwiftUI
import UniformTypeIdentifiers

struct MonthView: View {
    @EnvironmentObject var store: EntryStore
    let onEdit: (Entry) -> Void
    let onCreate: (Date) -> Void

    private var calendar: Calendar { Calendar.current }
    private var weekdaySymbols: [String] {
        var symbols = calendar.shortWeekdaySymbols
        let firstWeekday = calendar.firstWeekday - 1
        if firstWeekday > 0 {
            symbols = Array(symbols[firstWeekday...]) + Array(symbols[..<firstWeekday])
        }
        return symbols
    }

    var body: some View {
        VStack(spacing: 0) {
            // Month nav header
            HStack {
                Text(monthTitle)
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Button { changeMonth(-1) } label: { Image(systemName: "chevron.left") }
                Button("Today") {
                    store.displayedMonth = Date()
                    store.selectedDate = DateUtil.startOfDay(Date())
                }
                Button { changeMonth(1) } label: { Image(systemName: "chevron.right") }
            }
            .padding(16)

            Divider()

            // Weekday header
            HStack(spacing: 4) {
                ForEach(weekdaySymbols, id: \.self) { sym in
                    Text(sym)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            // Grid
            let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
            let days = daysInMonthGrid()
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(days, id: \.self) { day in
                    DayCell(
                        date: day,
                        isCurrentMonth: DateUtil.sameMonth(day, store.displayedMonth),
                        isSelected: DateUtil.sameDay(day, store.selectedDate),
                        isToday: calendar.isDateInToday(day),
                        entries: store.entries(on: day).filter { !$0.isParked }
                    )
                    .onTapGesture {
                        store.selectedDate = DateUtil.startOfDay(day)
                    }
                    .onTapGesture(count: 2) {
                        onCreate(DateUtil.startOfDay(day))
                    }
                    .modifier(DayCellDropModifier(day: day))
                }
            }
            .padding(16)

            Spacer(minLength: 0)
        }
    }

    private var monthTitle: String {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f.string(from: store.displayedMonth)
    }

    private func changeMonth(_ value: Int) {
        if let d = calendar.date(byAdding: .month, value: value, to: store.displayedMonth) {
            store.displayedMonth = d
        }
    }

    private func daysInMonthGrid() -> [Date] {
        guard let monthInterval = calendar.dateInterval(of: .month, for: store.displayedMonth) else { return [] }
        let firstOfMonth = monthInterval.start
        let firstWeekday = calendar.component(.weekday, from: firstOfMonth)
        let leadingDays = (firstWeekday - calendar.firstWeekday + 7) % 7
        guard let gridStart = calendar.date(byAdding: .day, value: -leadingDays, to: firstOfMonth) else { return [] }
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: gridStart) }
    }
}

/// Wraps `.dropDestination` with a highlighted overlay while hovered, so the
/// user sees which day they'll land on. Local modifier keeps the DayCell body
/// uncluttered.
private struct DayCellDropModifier: ViewModifier {
    let day: Date
    @EnvironmentObject var store: EntryStore
    @State private var isTargeted: Bool = false

    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.accentColor, lineWidth: isTargeted ? 2 : 0)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.accentColor.opacity(isTargeted ? 0.08 : 0))
                    )
                    .allowsHitTesting(false)
            )
            .onDrop(of: [.plainText, .text, .utf8PlainText], isTargeted: $isTargeted) { providers in
                LessonDrag.resolve(providers: providers, store: store) { entry in
                    try? store.scheduleEntry(entry, onto: day)
                }
            }
    }
}

private struct DayCell: View {
    let date: Date
    let isCurrentMonth: Bool
    let isSelected: Bool
    let isToday: Bool
    let entries: [Entry]

    @EnvironmentObject var store: EntryStore
    private let calendar = Calendar.current
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("\(calendar.component(.day, from: date))")
                    .font(.system(size: 12, weight: isToday ? .bold : .regular))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(isToday ? Color.orange : Color.clear, in: Circle())
                    .foregroundColor(isToday ? .white : (isCurrentMonth ? .primary : .secondary))
                Spacer()
            }

            ForEach(entries.prefix(3), id: \.id) { entry in
                EntryPill(entry: entry)
                    .lessonDraggable(entry)
                    .onDrop(of: [.plainText, .text, .utf8PlainText], isTargeted: nil) { providers in
                        LessonDrag.resolve(providers: providers, store: store) { dragged in
                            guard dragged.id != entry.id else { return }
                            let option = NSEvent.modifierFlags.contains(.option)
                            if option {
                                try? store.insertByCascade(dragged, atSlotOf: entry)
                            } else {
                                try? store.swapEntries(dragged, entry)
                            }
                        }
                    }
            }
            if entries.count > 3 {
                Text("+\(entries.count - 3) more")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(4)
        .frame(minHeight: 84, alignment: .topLeading)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isSelected ? Color.accentColor : Color(NSColor.separatorColor),
                              lineWidth: isSelected ? 1.5 : 0.5)
        )
        .opacity(isCurrentMonth ? 1.0 : 0.4)
    }

}

private struct EntryPill: View {
    let entry: Entry
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let firstTag = entry.tags.first
        let dark = scheme == .dark
        HStack(spacing: 4) {
            if let firstTag {
                Text(firstTag.uppercased())
                    .font(.system(size: 8, weight: .semibold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.black.opacity(dark ? 0.0 : 0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                    .lineLimit(1)
            }
            Text(entry.title)
                .font(.system(size: 10))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            firstTag.map { TagColor.background(for: $0, dark: dark) } ?? Color.accentColor.opacity(0.18)
        )
        .foregroundStyle(
            firstTag.map { TagColor.foreground(for: $0, dark: dark) } ?? Color.accentColor
        )
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}
