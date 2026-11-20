import SwiftUI

/// Click-to-preview / double-click-to-edit behaviour shared by every view.
///
/// - Single click opens a read-only popover preview of the lesson.
/// - Double click closes the preview and opens the editor.
///
/// Attach this to a plain view (not a Button, which would swallow the tap).
/// Buttons nested inside it (tags, resources, menus) keep working as before.
struct PreviewOrEdit: ViewModifier {
    let entry: Entry
    let onEdit: (Entry) -> Void
    var arrowEdge: Edge = .trailing

    @EnvironmentObject var store: EntryStore
    @EnvironmentObject var classroom: ClassroomClient
    @State private var showPreview = false
    @State private var showClassroom = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                showPreview = false
                onEdit(entry)
            }
            .onTapGesture {
                showPreview = true
            }
            .popover(isPresented: $showPreview, arrowEdge: arrowEdge) {
                EntryPreview(
                    entry: entry,
                    onEdit: {
                        showPreview = false
                        onEdit(entry)
                    },
                    onClassroom: {
                        showPreview = false
                        showClassroom = true
                    }
                )
                .environmentObject(store)
            }
            .sheet(isPresented: $showClassroom) {
                ClassroomPushSheet(entry: entry)
                    .environmentObject(store)
                    .environmentObject(classroom)
            }
    }
}

extension View {
    /// Single click = preview popover, double click = open the editor.
    func previewOrEdit(_ entry: Entry,
                       onEdit: @escaping (Entry) -> Void,
                       arrowEdge: Edge = .trailing) -> some View {
        modifier(PreviewOrEdit(entry: entry, onEdit: onEdit, arrowEdge: arrowEdge))
    }
}

/// Read-only lesson preview shown in the popover.
struct EntryPreview: View {
    let entry: Entry
    let onEdit: () -> Void
    let onClassroom: () -> Void
    @EnvironmentObject var store: EntryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                        .font(.headline)
                    Text(timeDisplay)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                           : "Google Classroom (already posted)…") { onClassroom() }
                    if entry.classSlug != nil && store.classConfig(for: entry.classSlug) != nil {
                        Divider()
                        Button("Pull forward one slot (just this)") {
                            do { try store.pullForward(entry) }
                            catch { store.errorMessage = error.localizedDescription }
                        }
                        Button("Bump back one slot (just this)") {
                            do { try store.bumpBack(entry) }
                            catch { store.errorMessage = error.localizedDescription }
                        }
                        Divider()
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
                Button("Edit", action: onEdit)
                    .controlSize(.small)
            }
            .padding(12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if !entry.tags.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(entry.tags, id: \.self) { t in
                                TagPill(tag: t, active: false)
                            }
                        }
                    }
                    if !entry.body.isEmpty {
                        MarkdownView(source: entry.body)
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
                    }
                    Text("Double-click a lesson to edit")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 680, height: 760)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var timeDisplay: String {
        let day = DateFormatter()
        day.dateFormat = "EEE d MMM yyyy"
        let d = day.string(from: entry.date)
        guard entry.hasTime else { return d + " · All day" }
        var s = d + " · " + DateUtil.formatTime(entry.date)
        if let end = entry.endDate { s += " – " + DateUtil.formatTime(end) }
        return s
    }
}
