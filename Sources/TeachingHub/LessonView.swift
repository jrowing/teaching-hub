import SwiftUI
import AppKit

/// Full-main-pane view of a single lesson. Opens on a single click of any
/// lesson in any calendar view. Shows the rendered markdown body, syllabus
/// statements, requirements and resources (as clickable links to the real
/// file on disk), with a toolbar for editing, bumping/pulling, PDF export,
/// Classroom push and open-in-Finder. ← / → navigate chronologically.
struct LessonView: View {
    let entry: Entry
    let onOpenLesson: (Entry) -> Void
    let onEdit: (Entry) -> Void
    let onClose: () -> Void

    @EnvironmentObject var store: EntryStore
    @EnvironmentObject var classroom: ClassroomClient
    @State private var showClassroomSheet: Bool = false
    @State private var keyMonitor: Any? = nil

    private let accent = Color(red: 0.42, green: 0.36, blue: 0.82)

    // Chronological neighbours for ← / → navigation.
    private var sorted: [Entry] { store.entries.sorted { $0.date < $1.date } }
    private var currentIndex: Int? { sorted.firstIndex(where: { $0.id == entry.id }) }
    private var previousEntry: Entry? {
        guard let i = currentIndex, i > 0 else { return nil }
        return sorted[i - 1]
    }
    private var nextEntry: Entry? {
        guard let i = currentIndex, i + 1 < sorted.count else { return nil }
        return sorted[i + 1]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    bodySection
                    if !entry.requirements.isEmpty && !entry.bodyFull.contains("## Requirements") {
                        requirementsSection
                    }
                    resourcesSection
                    footer
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 24)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
        .sheet(isPresented: $showClassroomSheet) {
            ClassroomPushSheet(entry: entry)
                .environmentObject(store)
                .environmentObject(classroom)
        }
        .onAppear { installKeyMonitor() }
        .onDisappear { removeKeyMonitor() }
        .onChange(of: entry.id) { _, _ in
            // Rebind the monitor so the captured neighbour computations are fresh.
            removeKeyMonitor(); installKeyMonitor()
        }
        .onChange(of: showClassroomSheet) { _, opening in
            // Don't swallow arrow keys while a modal sheet is up.
            if opening { removeKeyMonitor() } else { installKeyMonitor() }
        }
    }

    // MARK: - Arrow/Esc key monitor
    //
    // `.onKeyPress` doesn't fire reliably here because the inner ScrollView
    // captures arrow keys for scrolling before the modifier sees them. An
    // NSEvent local monitor grabs keyDown at the app level while this view is
    // on-screen, and returns nil for the arrows/esc so the ScrollView never
    // sees them. All other keys pass through unchanged.
    private func installKeyMonitor() {
        if keyMonitor != nil { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Let text fields and other first-responders keep their keys —
            // only swallow when no editable responder is active.
            if let responder = NSApp.keyWindow?.firstResponder,
               responder is NSTextView || responder is NSText {
                return event
            }
            // Arrow keys and some numeric-pad keys include .function / .numericPad /
            // .capsLock flags that aren't "user pressed Fn"; strip them so our
            // modifier-combination checks match what the user actually held.
            let mods = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .subtracting([.function, .numericPad, .capsLock, .help])
            let shift = mods.contains(.shift)
            let cmd = mods.contains(.command)
            let opt = mods.contains(.option)
            // Pure-modifier combinations we care about
            let plain         = mods.isEmpty
            let cmdShift      = mods == [.command, .shift]
            let cmdOptShift   = mods == [.command, .option, .shift]
            let cmdOnly       = mods == [.command]

            switch event.keyCode {
            // ← / → : previous / next lesson (plain)
            //        Reschedule when combined with modifiers.
            case 123:  // left arrow
                if plain, let prev = self.previousEntry {
                    self.onOpenLesson(prev); return nil
                }
                if cmdShift { try? self.store.pullForward(self.entry); self.reopenCurrent(); return nil }
                if cmdOptShift { try? self.store.pullForwardCascade(self.entry); self.reopenCurrent(); return nil }
            case 124:  // right arrow
                if plain, let next = self.nextEntry {
                    self.onOpenLesson(next); return nil
                }
                if cmdShift { try? self.store.bumpBack(self.entry); self.reopenCurrent(); return nil }
                if cmdOptShift { try? self.store.bumpBackCascade(self.entry); self.reopenCurrent(); return nil }

            // Up / down scroll
            case 126:  // up arrow
                if cmdOnly { Self.scrollLessonTo(.top) }
                else if shift { Self.scrollLessonBy(dy: -Self.pageStep) }
                else { Self.scrollLessonBy(dy: -Self.lineStep) }
                return nil
            case 125:  // down arrow
                if cmdOnly { Self.scrollLessonTo(.bottom) }
                else if shift { Self.scrollLessonBy(dy: Self.pageStep) }
                else { Self.scrollLessonBy(dy: Self.lineStep) }
                return nil

            // [ / ] : vim-style previous / next lesson
            case 33:   // [
                if plain, let prev = self.previousEntry { self.onOpenLesson(prev); return nil }
            case 30:   // ]
                if plain, let next = self.nextEntry { self.onOpenLesson(next); return nil }

            // ⌘⇧P : post to Classroom
            // Bare P    : park / unpark the current lesson
            case 35:   // P
                if cmdShift { self.showClassroomSheet = true; return nil }
                if plain {
                    if self.entry.isParked {
                        try? self.store.unparkEntry(self.entry)
                        self.reopenCurrent()
                    } else {
                        let next = self.nextEntry ?? self.previousEntry
                        try? self.store.parkEntry(self.entry)
                        self.store.showHoldingPen = true
                        if let next { self.onOpenLesson(next) } else { self.onClose() }
                    }
                    return nil
                }

            // ⌘⌫ : delete with confirmation
            case 51:   // delete / backspace
                if cmdOnly {
                    self.confirmDeleteAndClose()
                    return nil
                }

            case 53:   // escape — back to calendar
                self.onClose()
                return nil
            default:
                break
            }
            _ = shift; _ = cmd; _ = opt  // keep compiler quiet on fallthrough
            return event
        }
    }

    private func confirmDeleteAndClose() {
        let alert = NSAlert()
        alert.messageText = "Delete this lesson?"
        alert.informativeText = "\"\(entry.title)\" will be moved to the Trash. This also removes its folder and any resources inside it."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            let next = nextEntry ?? previousEntry
            do {
                try store.deleteEntry(entry)
                if let next {
                    onOpenLesson(next)
                } else {
                    onClose()
                }
            } catch {
                let e = NSAlert()
                e.messageText = "Couldn't delete"
                e.informativeText = error.localizedDescription
                e.runModal()
            }
        }
    }

    // MARK: - Programmatic scrolling (AppKit)

    private static let lineStep: CGFloat = 60
    private static let pageStep: CGFloat = 480

    private enum ScrollEdge { case top, bottom }

    /// Scroll the LessonView's ScrollView by `dy` points. Positive = down.
    private static func scrollLessonBy(dy: CGFloat) {
        guard let scroll = firstScrollView() else { return }
        let clip = scroll.contentView
        guard let doc = clip.documentView else { return }
        var origin = clip.documentVisibleRect.origin
        let maxY = max(0, doc.frame.height - clip.bounds.height)
        origin.y = max(0, min(maxY, origin.y + dy))
        clip.scroll(to: origin)
        scroll.reflectScrolledClipView(clip)
    }

    private static func scrollLessonTo(_ edge: ScrollEdge) {
        guard let scroll = firstScrollView() else { return }
        let clip = scroll.contentView
        guard let doc = clip.documentView else { return }
        let y: CGFloat
        switch edge {
        case .top:    y = 0
        case .bottom: y = max(0, doc.frame.height - clip.bounds.height)
        }
        clip.scroll(to: CGPoint(x: clip.documentVisibleRect.origin.x, y: y))
        scroll.reflectScrolledClipView(clip)
    }

    /// Walk the key window's view tree and return the first NSScrollView found.
    /// LessonView is the only full-pane view that uses a ScrollView when active,
    /// so this reliably picks up ours.
    private static func firstScrollView() -> NSScrollView? {
        guard let root = NSApp.keyWindow?.contentView else { return nil }
        return findScrollView(in: root)
    }

    private static func findScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for sub in view.subviews {
            if let found = findScrollView(in: sub) { return found }
        }
        return nil
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor {
            NSEvent.removeMonitor(m)
            keyMonitor = nil
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button(action: onClose) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text("Back")
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(accent)
            .help("Back to calendar view (Esc)")

            Divider().frame(height: 18)

            Button { onEdit(entry) } label: {
                Label("Edit", systemImage: "square.and.pencil")
            }
            .help("Edit lesson (⌘⏎)")
            .keyboardShortcut(.return, modifiers: .command)

            Menu {
                Button("Pull forward (previous slot)") {
                    try? store.pullForward(entry)
                    reopenCurrent()
                }
                Button("Bump back (next slot)") {
                    try? store.bumpBack(entry)
                    reopenCurrent()
                }
                Divider()
                Button("Pull forward + cascade later lessons") {
                    try? store.pullForwardCascade(entry)
                    reopenCurrent()
                }
                Button("Bump back + cascade later lessons") {
                    try? store.bumpBackCascade(entry)
                    reopenCurrent()
                }
            } label: {
                Label("Reschedule", systemImage: "calendar.badge.clock")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Menu {
                Button("This lesson") {
                    PDFExport.exportLesson(entry)
                }
                Button("This day") {
                    PDFExport.exportDay(entry.date, entries: store.entries)
                }
                Button("This week") {
                    PDFExport.exportWeek(anchoredAt: entry.date, entries: store.entries)
                }
                Button("This week — overview") {
                    PDFExport.exportWeekOverview(anchoredAt: entry.date, entries: store.entries)
                }
                if let topic = topicInfo {
                    Button("This topic — \(topic.title)") {
                        PDFExport.exportTopic(title: topic.title, entries: topic.entries)
                    }
                }
            } label: {
                Label("Export PDF", systemImage: "square.and.arrow.down")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button {
                showClassroomSheet = true
            } label: {
                Label("Post to Classroom", systemImage: "paperplane")
            }

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([entry.url])
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }

            if entry.isParked {
                Button {
                    try? store.unparkEntry(entry)
                    reopenCurrent()
                } label: {
                    Label("Unpark", systemImage: "tray.and.arrow.up")
                }
                .help("Return this lesson to the calendar at its stored date")
            } else {
                Button {
                    let next = nextEntry ?? previousEntry
                    try? store.parkEntry(entry)
                    store.showHoldingPen = true
                    if let next { onOpenLesson(next) } else { onClose() }
                } label: {
                    Label("Park", systemImage: "tray.and.arrow.down")
                }
                .help("Move to the Holding Pen, out of the normal schedule")
            }

            Spacer()

            // Prev / Next
            HStack(spacing: 2) {
                Button {
                    if let p = previousEntry { onOpenLesson(p) }
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.plain)
                .disabled(previousEntry == nil)
                .help("Previous lesson (←)")
                Button {
                    if let n = nextEntry { onOpenLesson(n) }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.plain)
                .disabled(nextEntry == nil)
                .help("Next lesson (→)")
            }
            .padding(.leading, 8)
        }
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if !entry.classDisplay.isEmpty {
                    chip(entry.classDisplay.uppercased(), bold: true, color: accent)
                }
                if let room = roomForThisLesson, !room.isEmpty {
                    chip(room, bold: false, color: .orange)
                }
                ForEach(entry.tags.prefix(6), id: \.self) { tag in
                    chip(tag, bold: false, color: .secondary)
                }
                Spacer(minLength: 0)
            }
            Text(entry.title)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Image(systemName: "calendar")
                    .foregroundStyle(.secondary)
                Text(headerDate)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                if !headerTime.isEmpty {
                    Image(systemName: "clock")
                        .foregroundStyle(.secondary)
                        .padding(.leading, 6)
                    Text(headerTime)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func chip(_ text: String, bold: Bool, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: bold ? .semibold : .regular))
            .kerning(bold ? 0.5 : 0)
            .foregroundStyle(color)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }

    /// Room assigned to this lesson's class/day in the class config, if any.
    private var roomForThisLesson: String? {
        guard let slug = entry.classSlug, let cfg = store.classConfig(for: slug) else { return nil }
        let weekday = Calendar.current.component(.weekday, from: entry.date)
        return cfg.periods.first(where: { $0.day.rawValue == weekday })?.room
    }

    private var headerDate: String {
        let f = DateFormatter()
        f.dateFormat = "EEEE d MMMM yyyy"
        return f.string(from: entry.date)
    }
    private var headerTime: String {
        guard entry.hasTime else { return "" }
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        if let end = entry.endDate {
            return "\(f.string(from: entry.date)) – \(f.string(from: end))"
        }
        return f.string(from: entry.date)
    }

    // MARK: - Body

    private var bodySection: some View {
        let body = entry.bodyFull.trimmingCharacters(in: .whitespacesAndNewlines)
        return Group {
            if body.isEmpty {
                Text("No body text. Hit Edit to add syllabus statements, requirements and notes.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .italic()
            } else {
                MarkdownView(source: body)
                    .font(.system(size: 14))
            }
        }
    }

    private var requirementsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("REQUIREMENTS")
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.8)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(entry.requirements, id: \.self) { req in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        Text(req).font(.system(size: 14))
                    }
                }
            }
        }
    }

    // MARK: - Resources

    private var resourcesSection: some View {
        Group {
            if !entry.resources.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("RESOURCES")
                        .font(.system(size: 10, weight: .semibold))
                        .kerning(0.8)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(entry.resources) { r in
                            resourceRow(r)
                        }
                    }
                }
            }
        }
    }

    private func resourceRow(_ r: Resource) -> some View {
        Button {
            NSWorkspace.shared.open(r.url)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: r.symbolName)
                    .font(.system(size: 18))
                    .foregroundStyle(accent)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(resolvedPath(for: r))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: r.size, countStyle: .file))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.gray.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.gray.opacity(0.18), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Open with default app") { NSWorkspace.shared.open(r.url) }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([r.url])
            }
            Divider()
            Button("Copy path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(resolvedPath(for: r), forType: .string)
            }
        }
    }

    private func resolvedPath(for r: Resource) -> String {
        let fm = FileManager.default
        if let dest = try? fm.destinationOfSymbolicLink(atPath: r.url.path), !dest.isEmpty {
            if dest.hasPrefix("/") { return dest }
            let base = r.url.deletingLastPathComponent().path
            return (base as NSString).appendingPathComponent(dest)
        }
        return r.url.path
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().padding(.vertical, 8)
            HStack {
                if let prev = previousEntry {
                    Button {
                        onOpenLesson(prev)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("← Previous")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Text(prev.title)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(accent)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                if let next = nextEntry {
                    Button {
                        onOpenLesson(next)
                    } label: {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("Next →")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Text(next.title)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(accent)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Text(entry.url.path)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    // MARK: - Helpers

    private var topicInfo: (title: String, entries: [Entry])? {
        let chapterURL = entry.folderURL.deletingLastPathComponent()
        let chapterSlug = chapterURL.lastPathComponent
        guard !chapterSlug.isEmpty else { return nil }
        let topicEntries = store.entries.filter {
            $0.folderURL.deletingLastPathComponent().lastPathComponent == chapterSlug
        }
        let title = chapterSlug
            .replacingOccurrences(of: #"^[a-z]\d+-"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "-", with: " ")
            .capitalized
        return (title, topicEntries)
    }

    /// After a reschedule the entry reloads; pick it back up by stable id.
    private func reopenCurrent() {
        let id = entry.id
        DispatchQueue.main.async {
            if let fresh = store.entries.first(where: { $0.id == id }) {
                onOpenLesson(fresh)
            } else {
                // Folder got renamed — fall back to looking up by title + date-ish.
                if let near = store.entries.first(where: { $0.title == entry.title }) {
                    onOpenLesson(near)
                } else {
                    onClose()
                }
            }
        }
    }
}

// MARK: - Entry helpers used by the view

private extension Entry {
    var classDisplay: String {
        guard let s = classSlug else { return "" }
        return s.replacingOccurrences(of: "-", with: " ").capitalized
    }
}
