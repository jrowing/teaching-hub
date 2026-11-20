import SwiftUI
import AppKit

/// Settings sheet hosting Apple Calendar sync and class timetable info.
/// Phase 3 will add view preferences.
struct SettingsSheet: View {
    @EnvironmentObject var sync: CalendarSync
    @EnvironmentObject var store: EntryStore
    @Environment(\.dismiss) private var dismiss
    @State private var editorTarget: ClassEditorTarget?
    @EnvironmentObject var classroom: ClassroomClient

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Settings")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    termsSection
                    classesSection
                    calendarSection
                    classroomSection
                }
                .padding(20)
            }
        }
        .frame(width: 560, height: 700)
        .sheet(item: $editorTarget) { target in
            ClassEditorSheet(target: target)
                .environmentObject(store)
        }
    }

    // MARK: - Terms

    @ViewBuilder
    private var termsSection: some View {
        let hasTerms = !store.terms.terms.isEmpty
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "calendar")
                    .font(.system(size: 18))
                    .foregroundStyle(Color(red: 0.42, green: 0.36, blue: 0.82))
                Text("Term dates")
                    .font(.headline)
                if !store.terms.yearLabel.isEmpty {
                    Text(store.terms.yearLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(hasTerms ? "\(store.terms.terms.count) terms · \(store.terms.holidays.count) holidays" : "not configured")
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.gray.opacity(0.15))
                    .foregroundStyle(.secondary)
                    .clipShape(Capsule())
            }

            if hasTerms {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(store.terms.terms.enumerated()), id: \.offset) { _, term in
                        HStack {
                            Text(term.name).font(.system(size: 12, weight: .medium))
                            Spacer()
                            Text("\(formatDate(term.start)) – \(formatDate(term.end))")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                    }
                    if !store.terms.holidays.isEmpty {
                        Divider().padding(.vertical, 2)
                        ForEach(Array(store.terms.holidays.enumerated()), id: \.offset) { _, h in
                            HStack {
                                Image(systemName: "sun.max.fill")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.orange)
                                Text(h.reason.isEmpty ? "Holiday" : h.reason)
                                    .font(.system(size: 11))
                                Spacer()
                                Text(formatDate(h.date))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                        }
                    }
                }
            } else {
                Text("Create `terms.conf` in your Teaching folder to define term start/end dates and holidays. Scheduling operations (Pull forward / Bump back) will then skip non-teaching days.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                openTermsFile()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: hasTerms ? "pencil" : "plus")
                    Text(hasTerms ? "Edit terms.conf" : "Create terms.conf")
                }
                .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.blue)
        }
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func formatDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "d MMM yyyy"
        return f.string(from: d)
    }

    private func openTermsFile() {
        guard let root = store.folderURL else { return }
        let url = root.appendingPathComponent("terms.conf")
        if !FileManager.default.fileExists(atPath: url.path) {
            let template = """
                # VISP term dates
                year: 2026-27

                # term: <name> | <start YYYY-MM-DD> | <end YYYY-MM-DD>
                term: Autumn 1 | 2026-09-01 | 2026-10-23
                term: Autumn 2 | 2026-11-02 | 2026-12-18

                # holiday: <YYYY-MM-DD> | <reason>
                # holiday: 2026-10-14 | Inset day
                """
            try? template.write(to: url, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Classes

    @ViewBuilder
    private var classesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "person.3.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Color(red: 0.42, green: 0.36, blue: 0.82))
                Text("Classes")
                    .font(.headline)
                Spacer()
                Text(store.classes.isEmpty ? "none configured" : "\(store.classes.count)")
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.gray.opacity(0.15))
                    .foregroundStyle(.secondary)
                    .clipShape(Capsule())
            }

            if store.classes.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Create a `classes/` folder inside your Teaching folder, and add one `<slug>.conf` file per class. The slug should match the top-level folder name for lessons of that class (e.g. `year-9.conf` for lessons under `year-9/`).")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("""
                    # year-9.conf
                    name: Year 9 Science

                    period: mon 09:30-10:30 room-203
                    period: wed 11:10-12:30 room-203
                    period: fri 13:10-14:30 room-lab-2
                    """)
                    .font(.system(.caption, design: .monospaced))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(NSColor.windowBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(store.classes) { cls in
                        classRow(cls)
                    }
                }
            }

            newClassMenu

            Button {
                openClassesFolder()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                    Text(store.classes.isEmpty ? "Open Teaching folder" : "Open classes folder")
                }
                .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.blue)
        }
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func classRow(_ cls: ClassConfig) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(cls.name)
                    .font(.system(size: 13, weight: .semibold))
                Text(cls.slug)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    editorTarget = ClassEditorTarget(slug: cls.slug, existing: cls)
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .help("Edit timetable")
                Button {
                    NSWorkspace.shared.open(cls.sourceURL)
                } label: {
                    Image(systemName: "doc.text")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .help("Open .conf in text editor")
            }
            if cls.periods.isEmpty {
                Text("(no periods defined)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(cls.periods, id: \.self) { p in
                    Text("· " + p.description)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    /// Offers every class folder that has lessons but no timetable yet, plus a blank option.
    @ViewBuilder
    private var newClassMenu: some View {
        let configured = Set(store.classes.map { $0.slug })
        let missing = store.allClassSlugs.filter { !configured.contains($0) }
        if !missing.isEmpty {
            Menu {
                ForEach(missing, id: \.self) { slug in
                    Button(slug) {
                        editorTarget = ClassEditorTarget(slug: slug, existing: nil)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                    Text("Add timetable for a class…")
                }
                .font(.system(size: 11))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private func openClassesFolder() {
        guard let root = store.folderURL else { return }
        let classesDir = root.appendingPathComponent("classes", isDirectory: true)
        try? FileManager.default.createDirectory(at: classesDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(classesDir)
    }

    @ViewBuilder
    private var calendarSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "calendar.badge.plus")
                    .font(.system(size: 18))
                    .foregroundStyle(Color(red: 0.42, green: 0.36, blue: 0.82))
                Text("Apple Calendar")
                    .font(.headline)
                Spacer()
                statusPill
            }

            Text("Syncs every lesson into a calendar in Calendar.app. By default Teaching Hub creates its own **Teaching Plan** calendar; if your iCloud account refuses new calendars you can point it at any existing calendar instead.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if sync.isEnabled {
                enabledControls
            } else {
                disabledControls
            }

            if sync.isAuthorized {
                calendarPicker
            }

            if let err = sync.lastError {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            disclaimer
        }
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Google Classroom

    @ViewBuilder
    private var classroomSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "graduationcap")
                    .font(.system(size: 18))
                    .foregroundStyle(Color(red: 0.42, green: 0.36, blue: 0.82))
                Text("Google Classroom")
                    .font(.headline)
                Spacer()
                Text(classroom.isSignedIn ? "Signed in" : "Not signed in")
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background((classroom.isSignedIn ? Color.green : Color.gray).opacity(0.15))
                    .foregroundStyle(classroom.isSignedIn ? .green : .secondary)
                    .clipShape(Capsule())
            }

            Text("Post a lesson to Classroom from its ⋯ menu. Only the lesson's `## Students` section and the files you tick are sent — nothing else leaves your Mac.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                TextField("Google OAuth client ID", text: $classroom.clientID)
                    .textFieldStyle(.roundedBorder)
                SecureField("Google OAuth client secret", text: $classroom.clientSecret)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: 8) {
                if classroom.isSignedIn {
                    Button("Sign out") { classroom.signOut() }
                } else {
                    Button("Sign in to Google") { Task { await classroom.signIn() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(!classroom.isConfigured || classroom.isBusy)
                }
                if classroom.isBusy {
                    ProgressView().controlSize(.small)
                    Text("Waiting for your browser…")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }

            if let err = classroom.lastError {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            DisclosureGroup("How to get a client ID") {
                Text("""
                1. Open console.cloud.google.com and create a project (use your school account).
                2. APIs & Services → Library: enable “Google Classroom API” and “Google Drive API”.
                3. OAuth consent screen: choose “Internal” if your school offers it, otherwise “External” and add yourself as a test user.
                4. Credentials → Create credentials → OAuth client ID → application type “Desktop app”.
                5. Paste the client ID and secret above, then Sign in.
                If sign-in is blocked, your Workspace admin may need to allow the app.
                """)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            }
            .font(.system(size: 11))
        }
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var statusPill: some View {
        if sync.isSyncing {
            HStack(spacing: 4) {
                ProgressView().controlSize(.small).scaleEffect(0.7)
                Text("Syncing…")
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        } else if sync.isEnabled {
            Text("Enabled")
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Color.green.opacity(0.15))
                .foregroundStyle(.green)
                .clipShape(Capsule())
        } else {
            Text("Disabled")
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Color.gray.opacity(0.15))
                .foregroundStyle(.secondary)
                .clipShape(Capsule())
        }
    }

    @ViewBuilder
    private var disabledControls: some View {
        Button("Enable sync to Apple Calendar") {
            Task { await sync.enableSync() }
        }
        .controlSize(.large)
        .buttonStyle(.borderedProminent)
        .padding(.top, 4)

        Text("You'll be asked to grant Calendar access. Teaching Hub only writes to its own calendar — it doesn't read your other events.")
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var enabledControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(sync.syncedEventCount) events synced")
                    .font(.system(size: 12))
                Spacer()
                if let last = sync.lastSyncedAt {
                    Text("Last sync: \(relativeTime(from: last))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                Button("Sync now") {
                    Task { await sync.syncNow() }
                }
                .disabled(sync.isSyncing)
                Button("Disable") {
                    sync.disableSync()
                }
                Spacer()
                Button("Remove all synced events") {
                    confirmAndWipe()
                }
                .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var calendarPicker: some View {
        let calendars = sync.availableCalendars()
        VStack(alignment: .leading, spacing: 6) {
            Text("Sync into")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            if calendars.isEmpty {
                Text("No writable calendars found. Open Calendar.app and make sure at least one account is set up.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                Picker("", selection: Binding(
                    get: { sync.pickedCalendarIdentifier ?? "" },
                    set: { newId in
                        if !newId.isEmpty {
                            sync.selectCalendar(identifier: newId)
                            if sync.isEnabled {
                                Task { await sync.syncNow() }
                            }
                        }
                    }
                )) {
                    Text("— create new Teaching Plan calendar —").tag("")
                    ForEach(groupedCalendars(calendars), id: \.source) { group in
                        Section(group.source) {
                            ForEach(group.calendars) { c in
                                Text(c.isTeachingPlan ? "\(c.title) (existing Teaching Plan)" : c.title).tag(c.id)
                            }
                        }
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                Text("Teaching Hub only writes to the calendar you choose.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.top, 4)
    }

    private struct CalendarGroup {
        let source: String
        let calendars: [CalendarSync.CalendarChoice]
    }

    private func groupedCalendars(_ list: [CalendarSync.CalendarChoice]) -> [CalendarGroup] {
        var order: [String] = []
        var map: [String: [CalendarSync.CalendarChoice]] = [:]
        for c in list {
            if map[c.sourceTitle] == nil {
                order.append(c.sourceTitle)
                map[c.sourceTitle] = []
            }
            map[c.sourceTitle]?.append(c)
        }
        return order.map { CalendarGroup(source: $0, calendars: map[$0] ?? []) }
    }

    @ViewBuilder
    private var disclaimer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("One-way sync", systemImage: "arrow.right")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Edit lessons in Teaching Hub. Changes you make to events directly in Calendar.app will be overwritten the next time the lesson changes.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 8)
    }

    private func confirmAndWipe() {
        let alert = NSAlert()
        alert.messageText = "Remove all synced events?"
        alert.informativeText = "This removes the Teaching Plan calendar and every event Teaching Hub created in it. Your lesson files are not affected. You can re-enable sync later."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            sync.wipeAll()
            sync.disableSync()
        }
    }

    private func relativeTime(from date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}
