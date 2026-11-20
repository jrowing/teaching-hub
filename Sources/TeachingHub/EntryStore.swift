import Foundation
import AppKit
import Combine

@MainActor
final class EntryStore: ObservableObject {
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var classes: [ClassConfig] = []
    @Published private(set) var terms: TermConfig = .empty
    @Published private(set) var folderURL: URL?
    @Published private(set) var isLoading: Bool = false
    @Published var errorMessage: String?

    /// Look up a loaded class config by slug (e.g. "year-9" from Entry.classSlug).
    func classConfig(for slug: String?) -> ClassConfig? {
        guard let slug else { return nil }
        return classes.first { $0.slug == slug }
    }

    /// Every class slug seen across loaded entries (whether or not there's a config file for it).
    /// Sorted alphabetically for stable UI.
    var allClassSlugs: [String] {
        var seen = Set<String>()
        for e in entries {
            if let slug = e.classSlug { seen.insert(slug) }
        }
        return seen.sorted()
    }

    /// Entries of a given class, in date order.
    func entries(forClass slug: String) -> [Entry] {
        entries.filter { $0.classSlug == slug }.sorted { $0.date < $1.date }
    }

    /// The scheme-of-work (topic) slug for an entry — the second path component if present.
    /// Returns nil for lessons at the class root (no topic subfolder).
    func topicSlug(for entry: Entry) -> String? {
        let parts = entry.relpath.split(separator: "/", omittingEmptySubsequences: true)
        return parts.count >= 3 ? String(parts[1]) : nil
    }

    // UI state
    @Published var selectedDate: Date = Calendar.current.startOfDay(for: Date())
    @Published var displayedMonth: Date = Date()
    @Published var weekAnchor: Date = Date()
    @Published var view: ViewMode = .month
    @Published var filterTag: String? = nil
    @Published var showRequirementsPanel: Bool = false
    @Published var showHoldingPen: Bool = false
    @Published var requirementsMode: RequirementsMode = .aggregated
    @Published var requirementsWeekAnchor: Date = Date()

    enum ViewMode: String { case month, week, timeline, classView = "class", year }

    /// Active class for the Class view (nil = pick one; user selects from a menu).
    @Published var activeClassSlug: String? = nil

    /// Academic year the Year view is currently showing (represented by Sep 1 of that year).
    /// Nil until the view is first opened; then the setter below snaps to Sep 1 of the current academic year.
    @Published var yearViewAnchor: Date = {
        let cal = Calendar.current
        let now = Date()
        let year = cal.component(.year, from: now)
        let month = cal.component(.month, from: now)
        // Academic year starts in September; before Sep use previous year
        let academicYear = (month >= 9) ? year : year - 1
        return cal.date(from: DateComponents(year: academicYear, month: 9, day: 1)) ?? now
    }()
    enum RequirementsMode: String { case aggregated, breakdown }

    private let folderPathKey = "TeachingHub.folderPath"
    private var folderMonitor: DispatchSourceFileSystemObject?
    private var monitoredFD: Int32 = -1
    private var debounceTask: Task<Void, Never>?

    init() {
        restoreFromPath()
    }

    // MARK: - Public actions

    func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select your Teaching folder"
        panel.prompt = "Open"
        if panel.runModal() == .OK, let url = panel.url {
            UserDefaults.standard.set(url.path, forKey: folderPathKey)
            setFolder(url)
        }
    }

    /// Open a folder whose URL is already known (used by the welcome screen
    /// to jump straight into the default iCloud Teaching folder).
    func setFolderDirectly(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: folderPathKey)
        setFolder(url)
    }

    func reload() { loadEntries() }

    func disconnect() {
        stopMonitoring()
        UserDefaults.standard.removeObject(forKey: folderPathKey)
        folderURL = nil
        entries = []
    }

    func revealInFinder(_ entry: Entry) {
        NSWorkspace.shared.activateFileViewerSelecting([entry.url])
    }

    func openInDefaultEditor(_ entry: Entry) {
        NSWorkspace.shared.open(entry.url)
    }

    // MARK: - Derived data

    func entries(on day: Date) -> [Entry] {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: day)
        return entries
            .filter { cal.isDate($0.date, inSameDayAs: dayStart) }
            .filter { filterTag == nil || $0.tags.contains(filterTag!) }
            .sorted(by: Entry.compareForDay)
    }

    func entriesInWeek(_ anchor: Date, weekStartsOn: Int = 2, includeWeekend: Bool = false) -> [Entry] {
        let weekStart = DateUtil.startOfWeek(anchor, weekStartsOn: weekStartsOn)
        let dayCount = includeWeekend ? 7 : 5
        let weekEnd = Calendar.current.date(byAdding: .day, value: dayCount, to: weekStart)!
        return entries
            .filter { $0.date >= weekStart && $0.date < weekEnd }
            .filter { filterTag == nil || $0.tags.contains(filterTag!) }
    }

    var allTagsWithCounts: [(String, Int)] {
        var counts: [String: Int] = [:]
        for e in entries {
            for t in e.tags { counts[t, default: 0] += 1 }
        }
        return counts.sorted { (a, b) in
            if a.value != b.value { return a.value > b.value }
            return a.key < b.key
        }.map { ($0.key, $0.value) }
    }

    // MARK: - CRUD

    /// Returns the relative paths of the newly-written files.
    @discardableResult
    func createEntries(
        title: String,
        date: Date,
        includeTime: Bool,
        endDate: Date?,
        tags: [String],
        body: String,
        requirements: [String],
        subfolder: String?,
        recurrenceUntil: Date?
    ) throws -> [String] {
        guard folderURL != nil else { throw NSError(domain: "TeachHub", code: 1, userInfo: [NSLocalizedDescriptionKey: "No folder open"]) }

        let occurrences = buildOccurrences(start: date, until: recurrenceUntil)
        var written: [String] = []

        for occDate in occurrences {
            var occEnd: Date? = nil
            if let endDate {
                let durationSec = endDate.timeIntervalSince(date)
                occEnd = occDate.addingTimeInterval(durationSec)
            }
            let markdown = MarkdownComposer.compose(
                title: title,
                date: occDate,
                includeTime: includeTime,
                endDate: occEnd,
                tags: tags,
                body: body,
                requirements: requirements,
                extraFields: []
            )
            let datePrefix = formatDatePrefix(occDate)
            let stem = "\(datePrefix)-\(slugify(title))"
            let parentDir = subfolderURL(subfolder)
            try ensureDirectoryExists(parentDir)

            // Folder-per-lesson: create <date-slug>/lesson.md inside the chosen parent.
            let lessonFolderName = pickAvailableFolderName(in: parentDir, stem: stem)
            let lessonFolderURL = parentDir.appendingPathComponent(lessonFolderName, isDirectory: true)
            try FileManager.default.createDirectory(at: lessonFolderURL, withIntermediateDirectories: true)
            let fileURL = lessonFolderURL.appendingPathComponent("lesson.md")
            try markdown.write(to: fileURL, atomically: true, encoding: .utf8)

            let relFolder = subfolder.flatMap { $0.isEmpty ? nil : $0 }.map { "\($0)/\(lessonFolderName)" } ?? lessonFolderName
            written.append("\(relFolder)/lesson.md")
        }

        loadEntries()
        if let firstDate = occurrences.first {
            selectedDate = DateUtil.startOfDay(firstDate)
            if !DateUtil.sameMonth(firstDate, displayedMonth) { displayedMonth = firstDate }
        }
        return written
    }

    func updateEntry(
        _ original: Entry,
        title: String,
        date: Date,
        includeTime: Bool,
        endDate: Date?,
        tags: [String],
        body: String,
        requirements: [String]
    ) throws {
        let extras = original.frontMatter
            .filter { !["title", "date", "tags", "end", "end_date", "duration", "created", "published"].contains($0.key.lowercased()) }
            .map { ($0.key, $0.value) }
        let markdown = MarkdownComposer.compose(
            title: title, date: date, includeTime: includeTime,
            endDate: endDate, tags: tags, body: body,
            requirements: requirements, extraFields: extras
        )
        try markdown.write(to: original.url, atomically: true, encoding: .utf8)
        loadEntries()
        selectedDate = DateUtil.startOfDay(date)
        if !DateUtil.sameMonth(date, displayedMonth) { displayedMonth = date }
    }

    func deleteEntry(_ entry: Entry) throws {
        // Delete the lesson.md file. If its folder is left empty (i.e. folder-per-lesson
        // with no resources), remove the folder too. Resources stay put — we never delete
        // files the user didn't explicitly target.
        try FileManager.default.removeItem(at: entry.url)
        let parent = entry.url.deletingLastPathComponent()
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: parent.path),
           contents.filter({ !$0.hasPrefix(".") }).isEmpty,
           parent != folderURL {
            try? FileManager.default.removeItem(at: parent)
        }
        loadEntries()
    }

    // MARK: - Scheduling operations (Phase 2)

    enum ScheduleError: LocalizedError {
        case noClassConfig(String)
        case noSlotFound(classSlug: String, periodCount: Int, searchDescription: String)
        case folderMoveFailed(String)
        var errorDescription: String? {
            switch self {
            case .noClassConfig(let slug):
                return "No timetable found for class \"\(slug)\". Create classes/\(slug).conf in your Teaching folder."
            case .noSlotFound(let slug, let count, let search):
                if count == 0 {
                    return "No periods defined for \"\(slug)\". Open Settings and check that classes/\(slug).conf has period lines (e.g. `period: mon | 08:15 | 09:30`)."
                }
                return "No slot in \"\(slug)\" for \(search). The class has \(count) period\(count == 1 ? "" : "s") but none fall within the next 180 days of term dates / holidays."
            case .folderMoveFailed(let reason):
                return "Couldn't move the lesson folder: \(reason)"
            }
        }
    }

    /// Move `entry` to `newDate`, preserving its time-of-day if it had one.
    /// Updates `date:` (and `end:` by the same delta) in lesson.md, and renames
    /// the containing folder to match the new date (if the folder name starts with
    /// the old date prefix).
    func moveEntry(_ entry: Entry, to newDate: Date) throws {
        let delta = newDate.timeIntervalSince(entry.date)
        let newEnd = entry.endDate.map { $0.addingTimeInterval(delta) }
        try rewriteEntry(entry, newDate: newDate, newEnd: newEnd)
        try renameLessonFolderIfDatePrefix(entry, to: newDate)
        loadEntries()
        selectedDate = DateUtil.startOfDay(newDate)
        if !DateUtil.sameMonth(newDate, displayedMonth) { displayedMonth = newDate }
    }

    /// Move the lesson to the previous valid slot for its class, per its timetable
    /// (and skipping holidays / out-of-term dates when terms.conf is configured).
    func pullForward(_ entry: Entry) throws {
        guard let slug = entry.classSlug, let config = classConfig(for: slug) else {
            throw ScheduleError.noClassConfig(entry.classSlug ?? "(unknown)")
        }
        guard let slot = config.previousSlot(before: entry.date, terms: terms) else {
            throw ScheduleError.noSlotFound(
                classSlug: slug,
                periodCount: config.periods.count,
                searchDescription: "pull-forward before \(entry.date.formatted())"
            )
        }
        try moveEntry(entry, to: slot.start)
    }

    /// Move the lesson to the next valid slot for its class, per its timetable.
    func bumpBack(_ entry: Entry) throws {
        guard let slug = entry.classSlug, let config = classConfig(for: slug) else {
            throw ScheduleError.noClassConfig(entry.classSlug ?? "(unknown)")
        }
        // Find the next slot strictly after this lesson's current slot start
        let searchStart = entry.date.addingTimeInterval(60)  // 1 minute buffer to skip the current slot
        guard let slot = config.nextSlot(onOrAfter: searchStart, terms: terms) else {
            throw ScheduleError.noSlotFound(
                classSlug: slug,
                periodCount: config.periods.count,
                searchDescription: "bump-back after \(entry.date.formatted())"
            )
        }
        try moveEntry(entry, to: slot.start)
    }

    // MARK: - Cascading scheduling ops

    /// Move `entry` AND every later lesson for the same class each one slot earlier.
    /// Useful when a lesson got cancelled and everything needs to pull up.
    /// Works outer-to-inner: moves the earliest lesson first so each target slot
    /// is empty when it's reached.
    func pullForwardCascade(_ entry: Entry) throws {
        try cascadeShift(startingAt: entry, direction: .forward)
    }

    /// Move `entry` AND every later lesson for the same class each one slot later.
    /// Useful when a lesson is extended, a day is lost, or something needs inserting.
    /// Works inner-to-outer: moves the LAST lesson first so each target slot is
    /// empty when it's reached, preventing folder-name collisions.
    func bumpBackCascade(_ entry: Entry) throws {
        try cascadeShift(startingAt: entry, direction: .backward)
    }

    private enum CascadeDirection { case forward, backward }

    private func cascadeShift(startingAt entry: Entry, direction: CascadeDirection) throws {
        guard let slug = entry.classSlug, let config = classConfig(for: slug) else {
            throw ScheduleError.noClassConfig(entry.classSlug ?? "(unknown)")
        }

        // On each iteration we re-scan `entries` and pick the lesson at the extreme
        // end of the range we're shifting — the earliest (for pull-forward) or latest
        // (for bump-back) lesson that hasn't moved yet. "Hasn't moved yet" is tracked
        // by a cursor date that advances past each lesson after it's moved.
        //
        // forward (pull up): move the EARLIEST lesson into its previous slot. Its old
        //                    slot is now empty, so next iteration's earliest-remaining
        //                    lesson (which may well be the one that USED to be right
        //                    behind it) can safely move into that just-vacated slot.
        //
        // backward (bump):   move the LATEST lesson into its next slot. Its old slot
        //                    is now empty, so the previous lesson can move into it.
        let anchorDate = entry.date
        let remainingCount = entries.filter {
            $0.classSlug == slug && $0.date >= anchorDate
        }.count
        guard remainingCount > 0 else { return }

        // We cap the loop at 2× the initial count as a safety belt against runaway loops.
        let maxIterations = remainingCount * 2
        var movedCount = 0
        var iteration = 0
        var lowerCursor = anchorDate                              // for forward direction
        var upperCursor = Date.distantFuture                      // for backward direction

        while movedCount < remainingCount && iteration < maxIterations {
            iteration += 1

            // Candidate = the entry at the extreme end of what's left unmoved.
            // forward direction tracks a LOWER cursor (moved ones are earlier than us now,
            // so we only look at dates >= lowerCursor).
            // backward direction tracks an UPPER cursor (moved ones are later than us now,
            // so we only look at dates <= upperCursor; we move latest unmoved each iter).
            let candidates = entries
                .filter { e in
                    e.classSlug == slug &&
                    e.date >= anchorDate &&
                    (direction == .forward ? e.date >= lowerCursor : e.date <= upperCursor)
                }
                .sorted { $0.date < $1.date }
            guard !candidates.isEmpty else { break }

            let fresh: Entry
            switch direction {
            case .forward:  fresh = candidates.first!   // earliest unmoved
            case .backward: fresh = candidates.last!    // latest unmoved
            }

            // Where does it go?
            let nextSlot: ClassConfig.SlotMatch?
            switch direction {
            case .forward:
                nextSlot = config.previousSlot(before: fresh.date, terms: terms)
            case .backward:
                let searchStart = fresh.date.addingTimeInterval(60)
                nextSlot = config.nextSlot(onOrAfter: searchStart, terms: terms)
            }
            guard let slot = nextSlot else {
                throw ScheduleError.noSlotFound(
                    classSlug: slug,
                    periodCount: config.periods.count,
                    searchDescription: "cascade \(direction == .forward ? "forward" : "backward") from \(fresh.date.formatted())"
                )
            }

            // Safety: if the "next slot" isn't actually moving the lesson, stop
            // (prevents infinite loops when a lesson can't move further).
            if abs(slot.start.timeIntervalSince(fresh.date)) < 30 { break }

            // Apply the move (rewrite + folder rename), WITHOUT the async reload
            let delta = slot.start.timeIntervalSince(fresh.date)
            let newEnd = fresh.endDate.map { $0.addingTimeInterval(delta) }
            try rewriteEntry(fresh, newDate: slot.start, newEnd: newEnd)
            try renameLessonFolderIfDatePrefix(fresh, to: slot.start)
            loadEntriesSync()  // sync so the next iteration sees the change
            movedCount += 1

            // Advance the cursor so the lesson we just moved is excluded from
            // the next iteration's candidate set.
            //
            // forward: we moved `fresh` from `fresh.date` to the EARLIER `slot.start`.
            //   The lesson we moved now sits BELOW anchorDate. Set lowerCursor to
            //   fresh.date + 1 so we skip the just-moved lesson and pick the next
            //   lesson that still sits where it was (now the earliest unmoved).
            //
            // backward: we moved `fresh` from `fresh.date` to the LATER `slot.start`.
            //   Shrink upperCursor to fresh.date - 1 so only the lessons still at
            //   their original (earlier) positions are candidates next time round.
            switch direction {
            case .forward:  lowerCursor = fresh.date.addingTimeInterval(1)
            case .backward: upperCursor = fresh.date.addingTimeInterval(-1)
            }
        }

        // Nudge the view to the first lesson of the class so the change is visible
        if let firstAfter = entries.first(where: { $0.classSlug == slug && $0.date >= anchorDate.addingTimeInterval(-7*24*3600) }) {
            selectedDate = DateUtil.startOfDay(firstAfter.date)
            if !DateUtil.sameMonth(firstAfter.date, displayedMonth) {
                displayedMonth = firstAfter.date
            }
        }
    }

    /// Merge key/value pairs into the lesson's YAML front-matter and
    /// rewrite lesson.md. Keys already present are overwritten; keys with
    /// an empty string are removed. Reserved keys (title/date/end/tags/…)
    /// are refused — those are owned by `moveEntry` / the editor.
    ///
    /// Used by Classroom-push to remember the posted-to course/kind/post-id
    /// so the lesson shows an "already posted" banner next time.
    func setFrontMatter(_ entry: Entry, set newValues: [String: String]) throws {
        let reserved: Set<String> = [
            "title", "date", "tags", "end", "end_date", "enddate",
            "duration", "created", "published"
        ]
        var merged = entry.frontMatter
        for (k, v) in newValues {
            if reserved.contains(k.lowercased()) { continue }
            if v.isEmpty { merged.removeValue(forKey: k) }
            else { merged[k] = v }
        }
        let extras = merged
            .filter { !reserved.contains($0.key.lowercased()) }
            .map { ($0.key, $0.value) }
            .sorted { $0.0 < $1.0 }
        let markdown = MarkdownComposer.compose(
            title: entry.title,
            date: entry.date,
            includeTime: entry.hasTime,
            endDate: entry.endDate,
            tags: entry.tags,
            body: entry.body,
            requirements: entry.requirements,
            extraFields: extras
        )
        try markdown.write(to: entry.url, atomically: true, encoding: .utf8)
        // Pick up the change in @Published entries so UI reacts.
        reload()
    }

    // MARK: - Scheduling internals

    private func rewriteEntry(_ entry: Entry, newDate: Date, newEnd: Date?) throws {
        let extras = entry.frontMatter
            .filter { !["title", "date", "tags", "end", "end_date", "duration", "created", "published"].contains($0.key.lowercased()) }
            .map { ($0.key, $0.value) }
        let markdown = MarkdownComposer.compose(
            title: entry.title,
            date: newDate,
            includeTime: entry.hasTime,
            endDate: newEnd,
            tags: entry.tags,
            body: entry.body,
            requirements: entry.requirements,
            extraFields: extras
        )
        try markdown.write(to: entry.url, atomically: true, encoding: .utf8)
    }

    /// If the lesson folder name starts with a date prefix (YYYY-MM-DD),
    /// rename it to match the new date. Otherwise leave the folder name alone.
    private func renameLessonFolderIfDatePrefix(_ entry: Entry, to newDate: Date) throws {
        let folder = entry.folderURL
        guard folder != folderURL else { return }  // flat .md at root — no folder to rename
        let oldName = folder.lastPathComponent
        let datePattern = #"^\d{4}-\d{2}-\d{2}"#
        guard oldName.range(of: datePattern, options: .regularExpression) != nil else { return }

        let newPrefix = formatDatePrefix(newDate)
        let tail = String(oldName.dropFirst(10))  // everything after YYYY-MM-DD
        let newName = newPrefix + tail
        if newName == oldName { return }  // same date, no rename needed

        let parent = folder.deletingLastPathComponent()
        let availableName = pickAvailableFolderName(in: parent, stem: newName)
        let newURL = parent.appendingPathComponent(availableName, isDirectory: true)
        do {
            try FileManager.default.moveItem(at: folder, to: newURL)
        } catch {
            throw ScheduleError.folderMoveFailed(error.localizedDescription)
        }
    }

    /// Folders that can be used as a parent for a new lesson. Excludes
    /// folders that are themselves lesson folders (contain a lesson.md), since
    /// a lesson shouldn't be nested inside another lesson.
    func subfolders() -> [String] {
        guard let folderURL else { return [""] }
        let fm = FileManager.default
        var found: Set<String> = [""]
        if let enumerator = fm.enumerator(at: folderURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator {
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                let rel = url.path.replacingOccurrences(of: folderURL.path + "/", with: "")
                if rel.contains("/.") { continue }
                // Skip if this folder contains a lesson.md (or any dated .md) — it's itself a lesson folder
                let hasLesson = (try? fm.contentsOfDirectory(atPath: url.path))?.contains { name in
                    name == "lesson.md" || name.hasSuffix(".md") && !name.hasPrefix(".")
                } ?? false
                if hasLesson { continue }
                found.insert(rel)
            }
        }
        return found.sorted()
    }

    // MARK: - Folder restore (no sandbox, just a path)

    private func setFolder(_ url: URL) {
        stopMonitoring()
        folderURL = url
        loadEntries()
        startMonitoring(url: url)
    }

    private func restoreFromPath() {
        guard let path = UserDefaults.standard.string(forKey: folderPathKey),
              !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue {
            setFolder(url)
        } else {
            // Folder was moved or deleted; clear so the user can pick again
            UserDefaults.standard.removeObject(forKey: folderPathKey)
        }
    }

    // MARK: - Scanning

    func loadEntries() {
        guard let folderURL else { return }
        isLoading = true
        let url = folderURL
        Task.detached(priority: .userInitiated) {
            let scanned = Self.scan(folder: url)
            await self.applyScannedEntries(scanned)
        }
    }

    /// Synchronous rescan used by cascade operations that need to see their own
    /// mid-flight changes between iterations (the async loadEntries wouldn't finish
    /// before the next iteration reads `entries`).
    func loadEntriesSync() {
        guard let folderURL else { return }
        let scanned = Self.scan(folder: folderURL)
        applyScannedEntries(scanned)
    }

    private func applyScannedEntries(_ scanned: [Entry]) {
        self.entries = scanned.sorted { $0.date < $1.date }
        // Refresh class configs and term dates alongside entries — cheap, and keeps everything in sync
        if let folderURL {
            self.classes = ClassConfig.loadAll(from: folderURL)
            self.terms = TermConfig.load(from: folderURL)
        }
        self.isLoading = false
    }

    private nonisolated static func scan(folder: URL) -> [Entry] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        // Phase 1: collect every file in the tree, grouped by containing folder.
        // (We can't use the lazy enumerator twice, so we materialize it once.)
        var allURLs: [URL] = []
        for case let url as URL in enumerator { allURLs.append(url) }

        // Build a map: folder path -> list of non-markdown sibling files.
        // These become the "resources" for whichever lesson.md lives in that folder.
        var siblingsByFolder: [String: [URL]] = [:]
        for url in allURLs {
            let ext = url.pathExtension.lowercased()
            // Skip markdown files and anything hidden — they're lessons, not resources
            if ["md", "markdown", "mdown"].contains(ext) { continue }
            if url.lastPathComponent.hasPrefix(".") { continue }
            // Skip directories (enumerator yields them too)
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir { continue }
            let parent = url.deletingLastPathComponent().path
            siblingsByFolder[parent, default: []].append(url)
        }

        var results: [Entry] = []
        for url in allURLs {
            let ext = url.pathExtension.lowercased()
            guard ["md", "markdown", "mdown"].contains(ext) else { continue }
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let parsed = FrontMatterParser.parse(contents)
            let dateStr = parsed.frontMatter["date"]
                ?? parsed.frontMatter["created"]
                ?? parsed.frontMatter["published"]
                ?? ""
            guard let (date, hasTime) = FrontMatterParser.parseDate(dateStr) else { continue }
            let title = parsed.frontMatter["title"]
                ?? url.deletingPathExtension().lastPathComponent

            var endDate: Date? = nil
            if let endStr = parsed.frontMatter["end"]
                ?? parsed.frontMatter["end_date"]
                ?? parsed.frontMatter["endDate"] {
                if let (e, _) = FrontMatterParser.parseDate(endStr), e > date {
                    endDate = e
                }
            }

            let tags = FrontMatterParser.parseTags(parsed.frontMatter["tags"])
            let (reqs, bodyWithout) = RequirementsParser.extract(from: parsed.body)

            let rel = url.path.replacingOccurrences(of: folder.path + "/", with: "")
            let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast

            // Resources = sibling files in the lesson's folder.
            // If multiple .md files share a folder, they all see the same resources —
            // that's acceptable because the convention is one lesson per folder.
            let lessonFolder = url.deletingLastPathComponent()
            let resourceURLs = siblingsByFolder[lessonFolder.path] ?? []
            let resources: [Resource] = resourceURLs
                .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
                .map { rURL in
                    let size = (try? rURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
                    return Resource(
                        id: rURL.path,
                        url: rURL,
                        name: rURL.lastPathComponent,
                        ext: rURL.pathExtension.lowercased(),
                        size: size
                    )
                }

            // Class slug = first path component under the root
            // (e.g. "year-9" for teaching/year-9/forces/2026-09-05-intro/lesson.md)
            let components = rel.split(separator: "/", omittingEmptySubsequences: true)
            let classSlug: String? = components.count >= 2 ? String(components.first!) : nil

            let entry = Entry(
                id: rel,
                url: url,
                folderURL: lessonFolder,
                relpath: rel,
                title: title,
                date: date,
                endDate: endDate,
                hasTime: hasTime,
                tags: tags,
                body: bodyWithout,
                bodyFull: parsed.body,
                requirements: reqs,
                frontMatter: parsed.frontMatter,
                lastModified: mod,
                resources: resources,
                classSlug: classSlug
            )
            results.append(entry)
        }
        return results
    }

    // MARK: - File watching

    private func startMonitoring(url: URL) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        monitoredFD = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.debounceReload()
            }
        }
        source.setCancelHandler { [weak self] in
            Task { @MainActor in
                if let f = self?.monitoredFD, f >= 0 {
                    close(f)
                    self?.monitoredFD = -1
                }
            }
        }
        source.resume()
        folderMonitor = source
    }

    private func debounceReload() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            if Task.isCancelled { return }
            self?.loadEntries()
        }
    }

    private func stopMonitoring() {
        folderMonitor?.cancel()
        folderMonitor = nil
    }

    // No deinit needed — EntryStore lives for the app's lifetime.
    // stopMonitoring() handles cleanup explicitly via disconnect().

    // MARK: - Helpers

    private func subfolderURL(_ subfolder: String?) -> URL {
        guard let folderURL else { fatalError("no folder") }
        guard let s = subfolder, !s.isEmpty else { return folderURL }
        return s.split(separator: "/").reduce(folderURL) { $0.appendingPathComponent(String($1)) }
    }

    private func ensureDirectoryExists(_ url: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    private func pickAvailableFilename(in dir: URL, stem: String) -> String {
        let fm = FileManager.default
        var candidate = "\(stem).md"
        var n = 2
        while fm.fileExists(atPath: dir.appendingPathComponent(candidate).path) {
            candidate = "\(stem)-\(n).md"
            n += 1
        }
        return candidate
    }

    /// Like pickAvailableFilename but for a sub-folder (no extension).
    private func pickAvailableFolderName(in dir: URL, stem: String) -> String {
        let fm = FileManager.default
        var candidate = stem
        var n = 2
        while fm.fileExists(atPath: dir.appendingPathComponent(candidate).path) {
            candidate = "\(stem)-\(n)"
            n += 1
        }
        return candidate
    }

    private func formatDatePrefix(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: d)
    }

    private func slugify(_ s: String) -> String {
        let lower = s.lowercased()
        var slug = ""
        var lastWasDash = false
        for ch in lower {
            if ch.isLetter || ch.isNumber {
                slug.append(ch)
                lastWasDash = false
            } else if !lastWasDash {
                slug.append("-")
                lastWasDash = true
            }
        }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if slug.count > 60 { slug = String(slug.prefix(60)) }
        return slug.isEmpty ? "entry" : slug
    }

    private func buildOccurrences(start: Date, until: Date?) -> [Date] {
        guard let until else { return [start] }
        var occurrences: [Date] = []
        var cursor = start
        let cal = Calendar.current
        let endOfDayUntil = cal.date(bySettingHour: 23, minute: 59, second: 59, of: until) ?? until
        while cursor <= endOfDayUntil && occurrences.count < 520 {
            occurrences.append(cursor)
            cursor = cal.date(byAdding: .day, value: 7, to: cursor) ?? cursor.addingTimeInterval(7 * 86400)
        }
        return occurrences
    }
}
