import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Entry & EntryStore extensions

extension Entry {
    /// A lesson with `parked: true` in its front-matter is in the Holding Pen —
    /// kept on disk for later use but hidden from calendar views.
    var isParked: Bool {
        (frontMatter["parked"]?.lowercased() ?? "") == "true"
    }
}

extension EntryStore {
    /// Lessons currently in the Holding Pen (sorted by their original date, newest first).
    var parkedEntries: [Entry] {
        entries.filter { $0.isParked }.sorted { $0.date > $1.date }
    }

    /// Lessons that calendar views should render.
    var scheduledEntries: [Entry] {
        entries.filter { !$0.isParked }
    }

    /// Mark a lesson as parked. The file stays in its folder but gains
    /// `parked: true` in its front-matter and disappears from calendar views.
    func parkEntry(_ entry: Entry) throws {
        try setFrontMatter(entry, set: ["parked": "true"])
    }

    /// Remove the parked flag. The lesson stays at its stored date; combine
    /// with `moveEntry(_:to:)` if you want to re-schedule it at the same time.
    func unparkEntry(_ entry: Entry) throws {
        try setFrontMatter(entry, set: ["parked": ""])
    }

    /// Look up an entry whose folder lives directly inside `chapter`, whose
    /// title matches, and whose stored date is within a second of `near`.
    /// `moveEntry` renames both folder and id, so after each move we have to
    /// re-fetch by stable traits — this is the stablest triple we've got.
    private func findEntry(inChapter chapter: URL, title: String, near date: Date) -> Entry? {
        entries.first(where: {
            $0.folderURL.deletingLastPathComponent() == chapter &&
            $0.title == title &&
            abs($0.date.timeIntervalSince(date)) < 2
        })
    }

    /// Swap two lessons' dates. Both end up where the other one was.
    /// If either is parked, it keeps its parked state (dates still swap so
    /// unparking later lands at a sensible time).
    func swapEntries(_ a: Entry, _ b: Entry) throws {
        guard a.id != b.id else { return }
        let aDate = a.date
        let bDate = b.date
        let aChapter = a.folderURL.deletingLastPathComponent()
        let bChapter = b.folderURL.deletingLastPathComponent()
        let aTitle = a.title
        let bTitle = b.title
        // A scratch date far in the past, guaranteed not to collide with any
        // real lesson. Unix epoch (1 Jan 1970) does the job.
        let scratch = Date(timeIntervalSince1970: 0)

        // 1. Move A to scratch so B can land where A was.
        try moveEntry(a, to: scratch)
        loadEntriesSync()  // moveEntry's own loadEntries() is async

        // 2. Move B to A's original date.
        guard let bFresh = findEntry(inChapter: bChapter, title: bTitle, near: bDate) else {
            throw ScheduleError.folderMoveFailed("couldn't find \(bTitle) after A moved aside")
        }
        try moveEntry(bFresh, to: aDate)
        loadEntriesSync()

        // 3. Move A from scratch to B's original date.
        guard let aFresh = findEntry(inChapter: aChapter, title: aTitle, near: scratch) else {
            throw ScheduleError.folderMoveFailed("couldn't find \(aTitle) at scratch")
        }
        try moveEntry(aFresh, to: bDate)
    }

    /// Cascade-insert `entry` into `target`'s slot: push target and every
    /// later lesson of its class forward by one slot, then drop `entry` into
    /// target's just-vacated slot. Throws `noSlotFound` if the tail runs past
    /// the end of the school year.
    func insertByCascade(_ entry: Entry, atSlotOf target: Entry) throws {
        guard let slug = target.classSlug, classConfig(for: slug) != nil else {
            throw ScheduleError.noClassConfig(target.classSlug ?? "(unknown)")
        }
        // Parked entry has no "slot" today; unpark first.
        if entry.isParked { try unparkEntry(entry) }

        let targetDate = target.date
        let entryChapter = entry.folderURL.deletingLastPathComponent()
        let entryTitle = entry.title
        let targetChapter = target.folderURL.deletingLastPathComponent()
        let targetTitle = target.title

        // Move the dragged entry out of the way (scratch) so the cascade on
        // target can reach every later-dated lesson of that class without
        // bumping into entry.
        let scratch = Date(timeIntervalSince1970: 0)
        let freshEntry = findEntry(inChapter: entryChapter, title: entryTitle, near: entry.date) ?? entry
        try moveEntry(freshEntry, to: scratch)
        loadEntriesSync()

        // Cascade target forward (= backward in slot-order).
        if let targetFresh = findEntry(inChapter: targetChapter, title: targetTitle, near: targetDate) {
            try bumpBackCascade(targetFresh)
            loadEntriesSync()
        }

        // Place the dragged entry at the now-vacant targetDate.
        guard let entryNow = findEntry(inChapter: entryChapter, title: entryTitle, near: scratch) else {
            throw ScheduleError.folderMoveFailed("couldn't find \(entryTitle) at scratch after cascade")
        }
        try moveEntry(entryNow, to: targetDate)
    }

    /// Schedule a lesson into a given day — parked or not — picking the first
    /// period that day's class config provides. Falls back to 09:00 if no
    /// matching slot exists (so lessons aren't lost on a day the class doesn't
    /// actually meet). Unparks the lesson if it was in the Holding Pen.
    func scheduleEntry(_ entry: Entry, onto day: Date) throws {
        let cal = Calendar.current
        let weekday = cal.component(.weekday, from: day)
        var target: Date = cal.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day

        if let slug = entry.classSlug, let config = classConfig(for: slug),
           let period = config.periods
            .filter({ $0.day.rawValue == weekday })
            .sorted(by: { $0.startMinutes < $1.startMinutes })
            .first {
            target = cal.date(bySettingHour: period.startMinutes / 60,
                              minute: period.startMinutes % 60,
                              second: 0, of: day) ?? target
        }

        // Clear parked flag first (independent write — if moveEntry fails we
        // don't want a half-unparked lesson left behind).
        if entry.isParked {
            try unparkEntry(entry)
            // setFrontMatter calls loadEntries() which is ASYNCHRONOUS, so our
            // `entries` array still carries the stale parked copy at this point.
            // A sync rescan picks up the new frontmatter before we moveEntry,
            // otherwise moveEntry's rewrite would re-stamp parked:true from the
            // stale cached entry and the lesson stays invisible to the calendar.
            loadEntriesSync()
        }
        // Re-fetch so moveEntry sees the fresh (now un-parked) version.
        let fresh = entries.first(where: { $0.id == entry.id }) ?? entry
        try moveEntry(fresh, to: target)
    }
}

// MARK: - Drag payload
//
// Strings are the most reliable drag payload on macOS — no Info.plist
// declaration needed, works everywhere Transferable is supported. We prefix
// the id with a sentinel so the drop side can distinguish "a lesson from
// Teaching Hub" from any other String drop (pasted text, a URL from Safari…).

enum LessonDrag {
    static let prefix = "teaching-hub-lesson:"

    static func payload(for entry: Entry) -> String { prefix + entry.id }

    /// Parse a drop String and return the matching Entry, or nil.
    @MainActor
    static func entry(in items: [String], from store: EntryStore) -> Entry? {
        guard let raw = items.first, raw.hasPrefix(prefix) else { return nil }
        let id = String(raw.dropFirst(prefix.count))
        return store.entries.first(where: { $0.id == id })
    }

    /// Supported UTI identifiers for our drag payload. We register as plain
    /// text under both common UTIs so drop sides matching either one find us.
    static let supportedTypeIdentifiers: [String] = [
        UTType.utf8PlainText.identifier,    // "public.utf8-plain-text"
        UTType.plainText.identifier,        // "public.plain-text"
    ]
    static let supportedUTTypes: [UTType] = [
        .utf8PlainText, .plainText, .text,
    ]

    /// Build an NSItemProvider that advertises the lesson's drag payload under
    /// both plain-text UTIs explicitly. The convenience `NSItemProvider(object:)`
    /// registers only under NSString's own UTIs, which some drop callers refuse.
    static func makeProvider(for entry: Entry) -> NSItemProvider {
        let payload = entry.dragPayload
        let provider = NSItemProvider()
        provider.suggestedName = entry.title
        for typeId in supportedTypeIdentifiers {
            provider.registerDataRepresentation(forTypeIdentifier: typeId,
                                                visibility: .ownProcess) { completion in
                let data = payload.data(using: .utf8) ?? Data()
                completion(data, nil)
                return nil
            }
        }
        return provider
    }

    /// Resolve a lesson from NSItemProviders asynchronously, then hand it to
    /// `handler` on the main thread. Call from inside `.onDrop` blocks.
    @MainActor
    static func resolve(providers: [NSItemProvider], store: EntryStore,
                        handler: @escaping @MainActor (Entry) -> Void) -> Bool {
        guard let provider = providers.first else { return false }
        // Pick the first UTI the provider says it has. We'd rather read raw
        // bytes than rely on NSString class loading — the former is far less
        // fussy about UTI matching.
        let typeId = supportedTypeIdentifiers.first(where: provider.hasItemConformingToTypeIdentifier)
            ?? UTType.plainText.identifier
        _ = provider.loadDataRepresentation(forTypeIdentifier: typeId) { data, _ in
            guard let data = data, let raw = String(data: data, encoding: .utf8) else { return }
            guard raw.hasPrefix(prefix) else { return }
            let id = String(raw.dropFirst(prefix.count))
            DispatchQueue.main.async {
                if let entry = store.entries.first(where: { $0.id == id }) {
                    handler(entry)
                }
            }
        }
        return true
    }
}

// MARK: - Drag-source shortcut

extension View {
    /// Attach a reliable drag source to a view using the classic NSItemProvider
    /// API. Registers under both plain-text UTIs explicitly so every onDrop
    /// destination that accepts plain text sees our payload.
    func lessonDraggable(_ entry: Entry) -> some View {
        self.onDrag { LessonDrag.makeProvider(for: entry) }
    }
}

/// Convenience: drag payload for an entry.
extension Entry {
    var dragPayload: String { LessonDrag.payload(for: self) }
}

// MARK: - Holding Pen panel

/// A right-hand sidebar that lists parked lessons as cards.
/// • Drop a scheduled lesson here to park it.
/// • Drag a parked lesson out onto a day in Week/Month to reschedule.
struct HoldingPenPanel: View {
    @EnvironmentObject var store: EntryStore
    let onOpenLesson: (Entry) -> Void

    @State private var isTargeted: Bool = false
    @State private var errorMessage: String? = nil

    private let accent = Color(red: 0.42, green: 0.36, blue: 0.82)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            if let err = errorMessage {
                Text(err)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .padding(8)
            }
        }
        .frame(width: 280)
        .background(Color(NSColor.windowBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 0)
                .stroke(isTargeted ? accent : Color.clear, lineWidth: 2)
        )
        // The whole panel is a drop target for scheduled lessons.
        .onDrop(of: [.plainText, .text, .utf8PlainText], isTargeted: $isTargeted) { providers in
            LessonDrag.resolve(providers: providers, store: store) { entry in
                if !entry.isParked {
                    try? store.parkEntry(entry)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "tray.fill")
                .foregroundStyle(accent)
            Text("Holding Pen")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Text("\(store.parkedEntries.count)")
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(Color.gray.opacity(0.15))
                .clipShape(Capsule())
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        if store.parkedEntries.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "tray")
                    .font(.system(size: 28))
                    .foregroundStyle(.tertiary)
                Text("Drop a lesson here to park it out of the schedule.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                Text("Drag parked lessons onto a day in Week or Month view to reschedule.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } else {
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(store.parkedEntries) { entry in
                        parkedCard(entry)
                    }
                }
                .padding(10)
            }
        }
    }

    private func parkedCard(_ entry: Entry) -> some View {
        // Using a plain VStack with onTapGesture instead of a Button so
        // `.draggable` isn't swallowed by the Button's gesture priority.
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            HStack(spacing: 6) {
                if !entry.classDisplay.isEmpty {
                    Text(entry.classDisplay)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(accent)
                }
                Spacer()
                Text(DateFormatterCache.shortDay.string(from: entry.date))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(Color.gray.opacity(0.18), lineWidth: 0.5)
        )
        // `.contentShape` makes the whole padded rectangle grab the tap, not just
        // the text inside. Important: apply before the gesture / drag modifiers.
        .contentShape(Rectangle())
        .onTapGesture {
            onOpenLesson(entry)
        }
        .lessonDraggable(entry)
        .contextMenu {
            Button("Open lesson") { onOpenLesson(entry) }
            Divider()
            Button("Unpark (keeps its current date)") {
                try? store.unparkEntry(entry)
            }
            Button("Open folder in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([entry.url])
            }
        }
    }

}

// MARK: - Shared formatters

enum DateFormatterCache {
    static let shortDay: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE d MMM"; return f
    }()
}

// MARK: - Entry display helpers

private extension Entry {
    var classDisplay: String {
        guard let s = classSlug else { return "" }
        return s.replacingOccurrences(of: "-", with: " ").capitalized
    }
}
