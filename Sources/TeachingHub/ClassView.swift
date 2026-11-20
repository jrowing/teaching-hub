import SwiftUI

/// Long-term view for a single class: every lesson, grouped by scheme-of-work
/// (topic folder), with lesson counts and date ranges per topic. Collapsible sections.
///
/// Topic groupings come from the second path component of a lesson's relpath
/// (e.g. `year-9/forces/2026-09-05-intro/lesson.md` → topic "forces"). Lessons
/// without a topic subfolder go into an "Uncategorized" group at the bottom.
struct ClassView: View {
    @EnvironmentObject var store: EntryStore
    let onEdit: (Entry) -> Void

    @State private var collapsedTopics: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let slug = store.activeClassSlug {
                content(forClass: slug)
            } else {
                picker
            }
        }
    }

    // MARK: - Header + class picker

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.3.fill")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
            if let slug = store.activeClassSlug {
                let name = store.classConfig(for: slug)?.name ?? slug
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.title2).fontWeight(.semibold)
                    Text(slug).font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            } else {
                Text("Pick a class").font(.title2).fontWeight(.semibold)
            }
            Spacer()
            classMenu
        }
        .padding(16)
    }

    @ViewBuilder
    private var classMenu: some View {
        if !store.allClassSlugs.isEmpty {
            Menu {
                ForEach(store.allClassSlugs, id: \.self) { slug in
                    Button {
                        store.activeClassSlug = slug
                    } label: {
                        let name = store.classConfig(for: slug)?.name ?? slug
                        Text(name)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text("Change class")
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9))
                }
                .font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    @ViewBuilder
    private var picker: some View {
        if store.allClassSlugs.isEmpty {
            emptyState
        } else {
            VStack(spacing: 12) {
                Text("Choose a class to see all its lessons grouped by topic.")
                    .foregroundStyle(.secondary)
                ForEach(store.allClassSlugs, id: \.self) { slug in
                    Button {
                        store.activeClassSlug = slug
                    } label: {
                        HStack {
                            let name = store.classConfig(for: slug)?.name ?? slug
                            Text(name).fontWeight(.medium)
                            Spacer()
                            Text("\(store.entries(forClass: slug).filter { !$0.isParked }.count) lessons")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(12)
                        .frame(maxWidth: 400)
                        .background(Color(NSColor.controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(40)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("No classes yet")
                .foregroundStyle(.secondary)
            Text("Create a lesson under a `<class>/` top-level folder, e.g. `year-9/forces/2026-09-05-intro/lesson.md`.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Content

    @ViewBuilder
    private func content(forClass slug: String) -> some View {
        let groups = topicGroups(forClass: slug)
        if groups.isEmpty {
            Text("No lessons for this class yet.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    classSummary(groups: groups)
                    ForEach(groups, id: \.topic) { group in
                        topicSection(group)
                    }
                }
                .padding(16)
            }
        }
    }

    @ViewBuilder
    private func classSummary(groups: [TopicGroup]) -> some View {
        let total = groups.reduce(0) { $0 + $1.entries.count }
        let topicCount = groups.filter { $0.topic != uncategorizedKey }.count
        HStack(spacing: 16) {
            summaryTile(label: "Lessons", value: "\(total)")
            summaryTile(label: "Topics", value: "\(topicCount)")
            if let first = groups.first?.entries.first?.date,
               let last = groups.last?.entries.last?.date {
                summaryTile(label: "Span", value: spanLabel(from: first, to: last))
            }
        }
    }

    @ViewBuilder
    private func summaryTile(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
            Text(value)
                .font(.system(size: 18, weight: .semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func topicSection(_ group: TopicGroup) -> some View {
        let collapsed = collapsedTopics.contains(group.topic)
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if collapsed { collapsedTopics.remove(group.topic) }
                else { collapsedTopics.insert(group.topic) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                    Text(group.displayName)
                        .font(.system(size: 14, weight: .semibold))
                    Text("\(group.entries.count)")
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color(NSColor.separatorColor).opacity(0.5))
                        .foregroundStyle(.secondary)
                        .clipShape(Capsule())
                    Spacer()
                    if let first = group.entries.first?.date,
                       let last = group.entries.last?.date {
                        Text(spanLabel(from: first, to: last))
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if !collapsed {
                VStack(spacing: 4) {
                    ForEach(group.entries, id: \.id) { entry in
                        lessonRow(entry)
                            .lessonDraggable(entry)
                    }
                }
                .padding(.leading, 18)
                .padding(.bottom, 8)
            }
            Divider()
        }
    }

    @ViewBuilder
    private func lessonRow(_ entry: Entry) -> some View {
        Button { onEdit(entry) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(DateUtil.formatShortDate(entry.date))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .leading)
                Text(entry.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Spacer()
                if !entry.resources.isEmpty {
                    HStack(spacing: 2) {
                        Image(systemName: "paperclip")
                            .font(.system(size: 9))
                        Text("\(entry.resources.count)")
                            .font(.system(size: 10))
                    }
                    .foregroundStyle(.tertiary)
                }
                if !entry.requirements.isEmpty {
                    HStack(spacing: 2) {
                        Image(systemName: "checklist")
                            .font(.system(size: 9))
                        Text("\(entry.requirements.count)")
                            .font(.system(size: 10))
                    }
                    .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Grouping

    private static let uncategorizedKey = "__uncat"
    private var uncategorizedKey: String { Self.uncategorizedKey }

    struct TopicGroup {
        let topic: String             // slug or __uncat
        let displayName: String
        let entries: [Entry]
    }

    private func topicGroups(forClass slug: String) -> [TopicGroup] {
        let classEntries = store.entries(forClass: slug).filter { !$0.isParked }
        var byTopic: [String: [Entry]] = [:]
        for e in classEntries {
            let key = store.topicSlug(for: e) ?? uncategorizedKey
            byTopic[key, default: []].append(e)
        }
        // Each topic group sorted by date, then groups sorted by their earliest lesson date
        return byTopic.map { (topic, entries) in
            TopicGroup(
                topic: topic,
                displayName: topic == uncategorizedKey ? "Uncategorized" : humanize(topic),
                entries: entries.sorted { $0.date < $1.date }
            )
        }
        .sorted { a, b in
            // Uncategorized always last
            if a.topic == uncategorizedKey { return false }
            if b.topic == uncategorizedKey { return true }
            return (a.entries.first?.date ?? Date.distantFuture) < (b.entries.first?.date ?? Date.distantFuture)
        }
    }

    private func humanize(_ slug: String) -> String {
        slug.replacingOccurrences(of: "-", with: " ").capitalized
    }

    private func spanLabel(from: Date, to: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        if Calendar.current.isDate(from, inSameDayAs: to) {
            return f.string(from: from)
        }
        return "\(f.string(from: from)) – \(f.string(from: to))"
    }
}
