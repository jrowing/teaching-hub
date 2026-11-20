import SwiftUI

/// Long-term overview: one row per class, one column per week across the
/// academic year. Each cell is colored by the class's tag; opacity scales
/// with lesson count. Click a cell to jump to that week in Week view.
///
/// The academic year starts on 1 September and runs 40 weeks (through June).
/// Navigate with the arrows to go to previous or next academic year.
struct YearView: View {
    @EnvironmentObject var store: EntryStore

    private let weeksToShow = 40
    private let cellWidth: CGFloat = 22
    private let cellHeight: CGFloat = 32
    private let labelWidth: CGFloat = 140

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if store.allClassSlugs.isEmpty {
                emptyState
            } else {
                ScrollView([.horizontal, .vertical]) {
                    VStack(alignment: .leading, spacing: 0) {
                        weekRuler
                        monthRuler
                        Divider().padding(.vertical, 4)
                        ForEach(store.allClassSlugs, id: \.self) { slug in
                            classRow(slug)
                        }
                    }
                    .padding(16)
                }
            }
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "chart.bar.doc.horizontal")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(academicYearLabel).font(.title2).fontWeight(.semibold)
                Text("\(weeksToShow) weeks · \(store.allClassSlugs.count) classes")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button { navigateYear(by: -1) } label: {
                Image(systemName: "chevron.left")
            }
            Button("This year") { navigateToCurrentAcademicYear() }
                .controlSize(.small)
            Button { navigateYear(by: 1) } label: {
                Image(systemName: "chevron.right")
            }
        }
        .padding(16)
    }

    private var academicYearLabel: String {
        let cal = Calendar.current
        let y1 = cal.component(.year, from: store.yearViewAnchor)
        let y2 = y1 + 1
        return "Academic year \(y1)–\(String(y2).suffix(2))"
    }

    private func navigateYear(by delta: Int) {
        if let newDate = Calendar.current.date(byAdding: .year, value: delta, to: store.yearViewAnchor) {
            store.yearViewAnchor = newDate
        }
    }

    private func navigateToCurrentAcademicYear() {
        let cal = Calendar.current
        let now = Date()
        let month = cal.component(.month, from: now)
        let year = cal.component(.year, from: now)
        let academicYear = (month >= 9) ? year : year - 1
        if let d = cal.date(from: DateComponents(year: academicYear, month: 9, day: 1)) {
            store.yearViewAnchor = d
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.bar.doc.horizontal")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("No classes to show")
                .foregroundStyle(.secondary)
            Text("Add lessons under top-level class folders to see them here.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Rulers

    /// Week numbers above the grid
    @ViewBuilder
    private var weekRuler: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: labelWidth, height: 16)
            ForEach(0..<weeksToShow, id: \.self) { i in
                Text(i.isMultiple(of: 4) ? "\(i + 1)" : "")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .frame(width: cellWidth, height: 16)
            }
        }
    }

    /// Month labels spanning the weeks they cover
    @ViewBuilder
    private var monthRuler: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: labelWidth, height: 18)
            ForEach(monthSpans, id: \.startWeek) { span in
                Text(span.label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: CGFloat(span.weekCount) * cellWidth, height: 18, alignment: .leading)
            }
        }
    }

    struct MonthSpan {
        let label: String
        let startWeek: Int    // first week-index this month covers
        let weekCount: Int
    }

    /// Compute which weeks correspond to each month, labeling the month at its start.
    private var monthSpans: [MonthSpan] {
        let cal = Calendar.current
        var spans: [MonthSpan] = []
        var currentMonth: Int? = nil
        var startWeek: Int = 0
        var count: Int = 0
        let f = DateFormatter()
        f.dateFormat = "MMM"

        func flush(endingAt weekIdx: Int) {
            guard count > 0, let m = currentMonth else { return }
            var comps = DateComponents()
            comps.year = cal.component(.year, from: store.yearViewAnchor)
            comps.month = m
            comps.day = 1
            let d = cal.date(from: comps) ?? store.yearViewAnchor
            spans.append(MonthSpan(label: f.string(from: d), startWeek: startWeek, weekCount: count))
        }

        for i in 0..<weeksToShow {
            if let weekStart = cal.date(byAdding: .weekOfYear, value: i, to: store.yearViewAnchor) {
                let m = cal.component(.month, from: weekStart)
                if m != currentMonth {
                    flush(endingAt: i)
                    currentMonth = m
                    startWeek = i
                    count = 1
                } else {
                    count += 1
                }
            }
        }
        flush(endingAt: weeksToShow)
        return spans
    }

    // MARK: - Class row

    @ViewBuilder
    private func classRow(_ slug: String) -> some View {
        let name = store.classConfig(for: slug)?.name ?? humanize(slug)
        let maxCount = maxLessonsInAnyWeek(forClass: slug)
        HStack(spacing: 0) {
            Button {
                store.filterTag = slug  // many classes also appear as tags
                store.activeClassSlug = slug
                store.view = .classView
            } label: {
                HStack {
                    Text(name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(width: labelWidth - 10, alignment: .leading)
                }
                .padding(.vertical, 2)
            }
            .buttonStyle(.plain)
            .help("Open class view for \(name)")
            .frame(width: labelWidth, alignment: .leading)

            ForEach(0..<weeksToShow, id: \.self) { weekIdx in
                cell(forClass: slug, weekIndex: weekIdx, maxCount: maxCount)
            }
        }
    }

    @ViewBuilder
    private func cell(forClass slug: String, weekIndex: Int, maxCount: Int) -> some View {
        let lessons = lessons(forClass: slug, weekIndex: weekIndex)
        let count = lessons.count
        let intensity: Double = (count > 0 && maxCount > 0)
            ? 0.25 + 0.75 * (Double(count) / Double(maxCount))
            : 0
        let baseColor = TagColor.background(for: slug)
        let fill = count > 0 ? baseColor.opacity(intensity) : Color.clear
        let topics = Set(lessons.compactMap { store.topicSlug(for: $0) })
        let tooltipParts: [String] = {
            var parts: [String] = []
            parts.append(weekLabel(weekIndex))
            parts.append("\(count) \(count == 1 ? "lesson" : "lessons")")
            if !topics.isEmpty { parts.append("Topics: " + topics.sorted().joined(separator: ", ")) }
            return parts
        }()

        Button {
            if count > 0, let weekStart = weekStart(weekIndex) {
                store.weekAnchor = weekStart
                store.selectedDate = weekStart
                if !DateUtil.sameMonth(weekStart, store.displayedMonth) { store.displayedMonth = weekStart }
                store.view = .week
            }
        } label: {
            Rectangle()
                .fill(fill)
                .frame(width: cellWidth - 2, height: cellHeight - 2)
                .overlay(
                    Rectangle()
                        .stroke(Color(NSColor.separatorColor).opacity(0.3), lineWidth: 0.5)
                )
                .padding(1)
        }
        .buttonStyle(.plain)
        .disabled(count == 0)
        .help(tooltipParts.joined(separator: " · "))
    }

    // MARK: - Data

    private func weekStart(_ index: Int) -> Date? {
        Calendar.current.date(byAdding: .weekOfYear, value: index, to: store.yearViewAnchor)
    }

    private func weekLabel(_ index: Int) -> String {
        guard let start = weekStart(index) else { return "" }
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        return "Week of \(f.string(from: start))"
    }

    private func lessons(forClass slug: String, weekIndex: Int) -> [Entry] {
        guard let start = weekStart(weekIndex) else { return [] }
        let end = Calendar.current.date(byAdding: .day, value: 7, to: start) ?? start
        return store.entries.filter { e in
            e.classSlug == slug && e.date >= start && e.date < end
        }
    }

    private func maxLessonsInAnyWeek(forClass slug: String) -> Int {
        (0..<weeksToShow)
            .map { lessons(forClass: slug, weekIndex: $0).count }
            .max() ?? 0
    }

    private func humanize(_ slug: String) -> String {
        slug.replacingOccurrences(of: "-", with: " ").capitalized
    }
}
