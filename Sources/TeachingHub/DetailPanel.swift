import SwiftUI

struct DetailPanel: View {
    @EnvironmentObject var store: EntryStore
    let onEdit: (Entry) -> Void
    let onCreate: (Date) -> Void

    var body: some View {
        let entries = store.entries(on: store.selectedDate)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(formattedDate)
                        .font(.title3)
                        .fontWeight(.semibold)
                    Text("\(entries.count) \(entries.count == 1 ? "entry" : "entries")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { onCreate(store.selectedDate) } label: {
                    Image(systemName: "plus")
                }
                .help("New entry on this day")
            }
            .padding(16)
            Divider()

            if entries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text("No entries")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(entries, id: \.id) { entry in
                            EntryCard(entry: entry, onEdit: onEdit)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .background(Color(NSColor.controlBackgroundColor).opacity(0.4))
    }

    private var formattedDate: String {
        let f = DateFormatter()
        f.dateStyle = .full
        return f.string(from: store.selectedDate)
    }
}

private struct EntryCard: View {
    let entry: Entry
    let onEdit: (Entry) -> Void
    @EnvironmentObject var store: EntryStore
    @EnvironmentObject var classroom: ClassroomClient
    @State private var showClassroom = false

    var body: some View {
        cardContent
            .sheet(isPresented: $showClassroom) {
                ClassroomPushSheet(entry: entry)
                    .environmentObject(store)
                    .environmentObject(classroom)
            }
    }

    private var cardContent: some View {
        Group {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title)
                            .font(.headline)
                        Text(entry.relpath)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Menu {
                        Button("Open in default editor") { store.openInDefaultEditor(entry) }
                        Button("Reveal in Finder") { store.revealInFinder(entry) }
                        Divider()
                        Button(entry.frontMatter["classroom_post"] == nil
                               ? "Post to Google Classroom…"
                               : "Google Classroom (already posted)…") { showClassroom = true }
                        if entry.classSlug != nil && store.classConfig(for: entry.classSlug) != nil {
                            Divider()
                            // Single-lesson moves
                            Button("Pull forward one slot (just this)") {
                                do { try store.pullForward(entry) }
                                catch { store.errorMessage = error.localizedDescription }
                            }
                            Button("Bump back one slot (just this)") {
                                do { try store.bumpBack(entry) }
                                catch { store.errorMessage = error.localizedDescription }
                            }
                            Divider()
                            // Cascading: this + every later lesson for the class
                            Button("Pull forward cascade (this + all later)") {
                                do { try store.pullForwardCascade(entry) }
                                catch { store.errorMessage = error.localizedDescription }
                            }
                            Button("Bump back cascade (this + all later)") {
                                do { try store.bumpBackCascade(entry) }
                                catch { store.errorMessage = error.localizedDescription }
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }

                Text(timeDisplay)
                    .font(.caption)
                    .foregroundStyle(.secondary)

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
                        .padding(.top, 4)
                }

                if !entry.requirements.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Requirements")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        ForEach(entry.requirements, id: \.self) { r in
                            HStack(alignment: .top, spacing: 6) {
                                Text("•").foregroundStyle(.secondary)
                                Text(r).font(.system(size: 12))
                            }
                        }
                    }
                    .padding(.top, 4)
                }

                if !entry.resources.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Resources")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                NSWorkspace.shared.open(entry.folderURL)
                            } label: {
                                HStack(spacing: 3) {
                                    Image(systemName: "folder")
                                    Text("Open folder")
                                }
                                .font(.system(size: 10))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                        ForEach(entry.resources) { r in
                            ResourceRow(resource: r)
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(NSColor.controlBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .previewOrEdit(entry, onEdit: onEdit, arrowEdge: .leading)
    }

    private var timeDisplay: String {
        guard entry.hasTime else { return "All day" }
        let s = DateUtil.formatTime(entry.date)
        if let end = entry.endDate {
            let mins = Int(end.timeIntervalSince(entry.date)) / 60
            let h = mins / 60, m = mins % 60
            var parts: [String] = []
            if h > 0 { parts.append("\(h)h") }
            if m > 0 { parts.append("\(m)m") }
            let dur = parts.joined(separator: " ")
            return "\(s) – \(DateUtil.formatTime(end)) · \(dur)"
        }
        return s
    }
}

/// Clickable row for a single attached resource — opens in the default app.
/// Uses SF Symbols chosen by file type (slides → stacked rectangles, PDF → doc, etc.)
struct ResourceRow: View {
    let resource: Resource

    var body: some View {
        Button {
            NSWorkspace.shared.open(resource.url)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: resource.symbolName)
                    .frame(width: 16)
                    .foregroundStyle(iconTint)
                Text(resource.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(formatSize(resource.size))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(Color(NSColor.windowBackgroundColor).opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color(NSColor.separatorColor).opacity(0.5), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(resource.url) }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([resource.url])
            }
        }
    }

    private var iconTint: Color {
        switch resource.kind {
        case .slides: return .orange
        case .pdf: return .red
        case .spreadsheet: return .green
        case .image: return .purple
        case .video, .audio: return .pink
        case .document: return .blue
        default: return .secondary
        }
    }

    private func formatSize(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let kb = Double(bytes) / 1024
        if kb < 1024 { return String(format: "%.0f KB", kb) }
        let mb = kb / 1024
        if mb < 1024 { return String(format: "%.1f MB", mb) }
        return String(format: "%.1f GB", mb / 1024)
    }
}
