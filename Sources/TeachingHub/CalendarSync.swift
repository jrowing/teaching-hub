import Foundation
import EventKit
import Combine

/// Keeps a dedicated iCloud calendar in sync with the Teaching Hub folder.
///
/// One-way sync: lesson folder → Calendar. Lessons are the source of truth.
/// Edits in Calendar.app are overwritten on next sync; deletes come back.
///
/// Strategy:
///   - Stores a map of entry.id → EKEvent.eventIdentifier in UserDefaults.
///   - On each sync, diffs current events against desired state: create missing,
///     update changed, delete orphans.
///   - Hooks `EntryStore.$entries` via Combine with a 2 s debounce so rapid
///     typing doesn't spam EventKit.
@MainActor
final class CalendarSync: ObservableObject {
    private let store: EntryStore
    private let eventStore = EKEventStore()
    private var cancellables: Set<AnyCancellable> = []
    private var debounceTask: Task<Void, Never>? = nil

    /// Name of the dedicated calendar in the user's iCloud account.
    static let calendarName = "Teaching Plan"
    /// UserDefaults key for the entry.id → eventIdentifier map.
    private let eventMapKey = "TeachingHub.calendarEventMap"
    /// UserDefaults key for whether sync is enabled.
    private let enabledKey = "TeachingHub.calendarSyncEnabled"
    /// UserDefaults key for identifier of our dedicated calendar.
    private let calendarIdKey = "TeachingHub.calendarIdentifier"

    @Published private(set) var isEnabled: Bool = false
    @Published private(set) var isAuthorized: Bool = false
    @Published private(set) var lastSyncedAt: Date? = nil
    @Published private(set) var lastError: String? = nil
    @Published private(set) var syncedEventCount: Int = 0
    @Published private(set) var isSyncing: Bool = false
    /// Identifier of the calendar we're syncing INTO. Nil = will try to create "Teaching Plan".
    /// Settable so the user can point at any writable calendar they already have —
    /// some iCloud accounts refuse new calendars with "that account does not allow
    /// calendars to be added or removed", in which case picking an existing one is the way.
    @Published var pickedCalendarIdentifier: String? = nil

    init(store: EntryStore) {
        self.store = store
        self.isEnabled = UserDefaults.standard.bool(forKey: enabledKey)
        self.pickedCalendarIdentifier = UserDefaults.standard.string(forKey: calendarIdKey)
        refreshAuthorizationStatus()

        // When the entries list changes, debounce and re-sync.
        store.$entries
            .dropFirst()  // skip initial load; sync happens explicitly from enableSync()
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.scheduleSync()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Public actions

    /// Prompt for Calendar permission if needed, find/create the dedicated calendar,
    /// and run an initial sync. Call this when the user flips the "Enable" switch.
    func enableSync() async {
        lastError = nil
        do {
            try await requestAccess()
            refreshAuthorizationStatus()
            guard isAuthorized else {
                lastError = "Calendar access was denied. Grant it in System Settings → Privacy & Security → Calendars."
                return
            }
            _ = try ensureCalendarExists()
            isEnabled = true
            UserDefaults.standard.set(true, forKey: enabledKey)
            await syncNow()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Stop syncing. Does NOT delete the calendar or its events —
    /// the user can remove them from Calendar.app if they want.
    func disableSync() {
        isEnabled = false
        UserDefaults.standard.set(false, forKey: enabledKey)
    }

    /// Delete every event this app has synced, then remove the dedicated calendar.
    /// Used when the user wants a clean slate.
    func wipeAll() {
        guard let calendar = dedicatedCalendar() else {
            clearEventMap()
            return
        }
        // Remove every event we know about
        let map = storedEventMap()
        for (_, eventId) in map {
            if let ev = eventStore.event(withIdentifier: eventId) {
                try? eventStore.remove(ev, span: .thisEvent, commit: false)
            }
        }
        try? eventStore.commit()
        // Remove the calendar itself
        try? eventStore.removeCalendar(calendar, commit: true)
        clearEventMap()
        UserDefaults.standard.removeObject(forKey: calendarIdKey)
        syncedEventCount = 0
    }

    /// Run a full sync right now. Safe to call any time while enabled.
    func syncNow() async {
        guard isEnabled else { return }
        guard isAuthorized else {
            lastError = "Not authorized to access Calendar."
            return
        }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let calendar = try ensureCalendarExists()
            try applySync(to: calendar)
            lastSyncedAt = Date()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Internal sync engine

    /// Debounced wrapper so rapid changes don't hammer EventKit.
    private func scheduleSync() {
        guard isEnabled, isAuthorized else { return }
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if Task.isCancelled { return }
            await self?.syncNow()
        }
    }

    /// Diff the current entries against the calendar and apply create / update / delete.
    private func applySync(to calendar: EKCalendar) throws {
        var map = storedEventMap()
        let desiredEntries = store.entries
        let desiredIds = Set(desiredEntries.map { $0.id })

        // DELETE: events for entries that no longer exist
        for (entryId, eventId) in map where !desiredIds.contains(entryId) {
            if let event = eventStore.event(withIdentifier: eventId) {
                try eventStore.remove(event, span: .thisEvent, commit: false)
            }
            map.removeValue(forKey: entryId)
        }

        // CREATE / UPDATE
        for entry in desiredEntries {
            let existing: EKEvent? = map[entry.id].flatMap { eventStore.event(withIdentifier: $0) }
            let event = existing ?? EKEvent(eventStore: eventStore)
            populate(event: event, from: entry, calendar: calendar)
            try eventStore.save(event, span: .thisEvent, commit: false)
            map[entry.id] = event.eventIdentifier
        }

        try eventStore.commit()

        saveEventMap(map)
        syncedEventCount = map.count
    }

    /// Fill in or overwrite an EKEvent's fields from a lesson entry.
    private func populate(event: EKEvent, from entry: Entry, calendar: EKCalendar) {
        event.calendar = calendar
        event.title = entry.title

        // Dates
        if entry.hasTime {
            event.startDate = entry.date
            event.endDate = entry.endDate ?? entry.date.addingTimeInterval(55 * 60)  // 55-min default
            event.isAllDay = false
        } else {
            event.startDate = Calendar.current.startOfDay(for: entry.date)
            event.endDate = Calendar.current.date(byAdding: .day, value: 1, to: event.startDate) ?? event.startDate
            event.isAllDay = true
        }

        // Location — class name plus room when we can match the lesson's time to
        // a period in the class's timetable config. Falls back to just the class
        // slug if there's no config (Phase 2 behavior), empty otherwise.
        event.location = locationString(for: entry)

        // Notes — body (truncated) + requirements as checkboxes
        var notes = ""
        let bodyTrimmed = entry.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !bodyTrimmed.isEmpty {
            notes = String(bodyTrimmed.prefix(800))
            if bodyTrimmed.count > 800 { notes += "…" }
        }
        if !entry.requirements.isEmpty {
            if !notes.isEmpty { notes += "\n\n" }
            notes += "Requirements:\n"
            for r in entry.requirements {
                notes += "☐ \(r)\n"
            }
        }
        if !entry.resources.isEmpty {
            if !notes.isEmpty { notes += "\n" }
            notes += "Resources: " + entry.resources.map(\.name).joined(separator: ", ")
        }
        event.notes = notes.isEmpty ? nil : notes

        // URL — the lesson's folder. On Mac this opens in Finder from Calendar.app,
        // showing every resource; on iPhone/iPad the file:// URL won't do much but
        // records the location for reference.
        event.url = entry.folderURL
    }

    /// Build the Calendar event's location field:
    ///   "Year 9 Science · room-203"   — when we have a class config and a matching period
    ///   "Year 9 Science"               — when we have a class config but no matching period (odd time)
    ///   "year-9"                       — when there's a class slug but no config file
    ///   nil                            — no class context at all
    private func locationString(for entry: Entry) -> String? {
        guard let slug = entry.classSlug, !slug.isEmpty else { return nil }
        guard let config = store.classConfig(for: slug) else { return slug }
        let cal = Calendar.current
        let weekday = cal.component(.weekday, from: entry.date)
        let hour = cal.component(.hour, from: entry.date)
        let minute = cal.component(.minute, from: entry.date)
        let mins = hour * 60 + minute
        let match = config.periods.first { period in
            period.day.rawValue == weekday &&
                abs(period.startMinutes - mins) <= 10  // 10-minute tolerance for date rounding
        }
        if let room = match?.room, !room.isEmpty {
            return "\(config.name) · \(room)"
        }
        return config.name
    }

    // MARK: - Calendar & access

    private func refreshAuthorizationStatus() {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(macOS 14.0, *) {
            // Only .fullAccess lets us list calendars (needed by the picker) and
            // create new ones. Write-only authorizes event writing into a *known*
            // calendar but can't see or create calendars — a dead end for us.
            isAuthorized = (status == .fullAccess)
        } else {
            isAuthorized = (status == .authorized)
        }
    }

    /// Request Calendar permission. On macOS 14+ we use the full-access API —
    /// write-only can't create calendars or list existing ones, which breaks
    /// both the auto-create and the picker fallback.
    private func requestAccess() async throws {
        if #available(macOS 14.0, *) {
            _ = try await eventStore.requestFullAccessToEvents()
        } else {
            _ = try await eventStore.requestAccess(to: .event)
        }
    }

    /// All writable calendars this user has, grouped by source name
    /// (iCloud, Local, Gmail, etc.). Used by the picker UI.
    struct CalendarChoice: Identifiable, Hashable {
        let id: String        // calendar identifier
        let title: String
        let sourceTitle: String
        let isTeachingPlan: Bool
    }

    func availableCalendars() -> [CalendarChoice] {
        eventStore.calendars(for: .event)
            .filter { $0.allowsContentModifications }
            .map { CalendarChoice(id: $0.calendarIdentifier,
                                  title: $0.title,
                                  sourceTitle: $0.source.title,
                                  isTeachingPlan: $0.title == Self.calendarName) }
            .sorted { lhs, rhs in
                if lhs.sourceTitle != rhs.sourceTitle { return lhs.sourceTitle < rhs.sourceTitle }
                return lhs.title < rhs.title
            }
    }

    /// Set the calendar the user wants to sync into. Call after authorization.
    /// Causes next syncNow() to use this calendar.
    func selectCalendar(identifier: String) {
        pickedCalendarIdentifier = identifier
        UserDefaults.standard.set(identifier, forKey: calendarIdKey)
    }

    /// Return the dedicated calendar — using the user's pick, an existing one of
    /// the right name, or creating one. On accounts that refuse new calendars
    /// (the "that account does not allow calendars to be added or removed" error),
    /// falls back to creating in the Local source, then finally surfaces a clear
    /// instruction to pick an existing calendar.
    @discardableResult
    private func ensureCalendarExists() throws -> EKCalendar {
        // 1. User's explicit pick wins, if it's still a writable calendar
        if let savedId = pickedCalendarIdentifier ?? UserDefaults.standard.string(forKey: calendarIdKey),
           let cal = eventStore.calendar(withIdentifier: savedId),
           cal.allowsContentModifications {
            return cal
        }

        // 2. A "Teaching Plan" calendar that already exists (previous install, manual create)
        if let existing = eventStore.calendars(for: .event).first(where: { $0.title == Self.calendarName && $0.allowsContentModifications }) {
            UserDefaults.standard.set(existing.calendarIdentifier, forKey: calendarIdKey)
            pickedCalendarIdentifier = existing.calendarIdentifier
            return existing
        }

        // 3. Try to create one. Order: iCloud → any CalDAV → Local.
        //    Each try may fail with "that account does not allow …"; fall through to next.
        let sources = eventStore.sources
        let iCloudSource = sources.first { $0.sourceType == .calDAV && $0.title.lowercased().contains("icloud") }
        let anyCalDAV = sources.first { $0.sourceType == .calDAV && $0 != iCloudSource }
        let localSource = sources.first { $0.sourceType == .local }

        var lastCreateError: Error? = nil
        for source in [iCloudSource, anyCalDAV, localSource].compactMap({ $0 }) {
            let new = EKCalendar(for: .event, eventStore: eventStore)
            new.title = Self.calendarName
            new.source = source
            new.cgColor = CGColor(red: 0.42, green: 0.36, blue: 0.82, alpha: 1.0)
            do {
                try eventStore.saveCalendar(new, commit: true)
                UserDefaults.standard.set(new.calendarIdentifier, forKey: calendarIdKey)
                pickedCalendarIdentifier = new.calendarIdentifier
                return new
            } catch {
                lastCreateError = error
                // keep trying the next source
            }
        }

        // 4. Nothing worked. Give the user something actionable.
        let writableNames = eventStore.calendars(for: .event)
            .filter { $0.allowsContentModifications }
            .map { "\"\($0.title)\"" }
            .prefix(4)
            .joined(separator: ", ")
        let suggestion = writableNames.isEmpty
            ? "Open System Settings → Internet Accounts, enable iCloud Calendars, then try again."
            : "Pick an existing calendar to sync into (e.g. \(writableNames)) using the picker below."
        let msg = "Couldn't create a new calendar. \(lastCreateError?.localizedDescription ?? "The account refused.") \(suggestion)"
        throw NSError(domain: "TeachHub.Calendar", code: 3,
                      userInfo: [NSLocalizedDescriptionKey: msg])
    }

    private func dedicatedCalendar() -> EKCalendar? {
        guard let savedId = UserDefaults.standard.string(forKey: calendarIdKey) else { return nil }
        return eventStore.calendar(withIdentifier: savedId)
    }

    // MARK: - Event map persistence

    private func storedEventMap() -> [String: String] {
        (UserDefaults.standard.dictionary(forKey: eventMapKey) as? [String: String]) ?? [:]
    }

    private func saveEventMap(_ map: [String: String]) {
        UserDefaults.standard.set(map, forKey: eventMapKey)
    }

    private func clearEventMap() {
        UserDefaults.standard.removeObject(forKey: eventMapKey)
    }
}
