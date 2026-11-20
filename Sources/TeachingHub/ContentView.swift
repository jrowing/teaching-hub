import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: EntryStore
    @EnvironmentObject var appDelegate: AppDelegate
    @EnvironmentObject var calendarSync: CalendarSync
    @EnvironmentObject var classroom: ClassroomClient
    @State private var editingEntry: Entry? = nil
    @State private var creatingForDate: Date? = nil
    @State private var showingSettings: Bool = false
    /// When non-nil, the main pane shows LessonView for this lesson instead
    /// of the normal calendar view. A single click on any lesson sets this;
    /// the view's Back button / Esc clears it.
    @State private var openedLesson: Entry? = nil

    var body: some View {
        Group {
            if store.folderURL == nil {
                WelcomeView()
            } else {
                MainView(
                    openedLesson: openedLesson,
                    onOpenLesson: { openedLesson = $0 },
                    onCloseLesson: { openedLesson = nil },
                    onEdit: { editingEntry = $0 },
                    onCreate: { creatingForDate = $0 },
                    onOpenSettings: { showingSettings = true }
                )
            }
        }
        .frame(minWidth: 1100, minHeight: 700)
        .sheet(item: $editingEntry) { entry in
            EntryEditor(mode: .edit(entry)) { editingEntry = nil }
                .environmentObject(store)
        }
        .sheet(isPresented: Binding(
            get: { creatingForDate != nil },
            set: { if !$0 { creatingForDate = nil } }
        )) {
            if let date = creatingForDate {
                EntryEditor(mode: .create(date)) { creatingForDate = nil }
                    .environmentObject(store)
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsSheet()
                .environmentObject(calendarSync)
                .environmentObject(store)
        }
        .alert("Error",
               isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { if !$0 { store.errorMessage = nil } }
               ),
               actions: { Button("OK", role: .cancel) {} },
               message: { Text(store.errorMessage ?? "") }
        )
        // Tray clicked an entry — open the lesson view for it
        .onChange(of: appDelegate.entryToOpen) { _, newValue in
            if let entry = newValue {
                openedLesson = entry
                appDelegate.entryToOpen = nil
            }
        }
        // File → New Entry pressed
        .onChange(of: appDelegate.newEntryRequested) { _, newValue in
            if newValue {
                creatingForDate = store.selectedDate
                appDelegate.newEntryRequested = false
            }
        }
        // Settings menu / ⌘, pressed
        .onChange(of: appDelegate.settingsRequested) { _, newValue in
            if newValue {
                showingSettings = true
                appDelegate.settingsRequested = false
            }
        }
    }
}

struct WelcomeView: View {
    @EnvironmentObject var store: EntryStore

    /// The default location for the Teaching folder — inside iCloud Drive
    /// so it syncs across Macs and (eventually) is reachable from iPhone/iPad.
    private var defaultTeachingFolder: URL {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Teaching", isDirectory: true)
        return base
    }

    private var defaultFolderExists: Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: defaultTeachingFolder.path, isDirectory: &isDir) && isDir.boolValue
    }

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "graduationcap.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color(red: 0.42, green: 0.36, blue: 0.82))
            Text("Teaching Hub")
                .font(.title)
                .fontWeight(.semibold)
            Text("Your lesson plans, resources, and PowerPoints in one folder — on a calendar.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 440)

            VStack(spacing: 8) {
                if defaultFolderExists {
                    Button("Open Teaching folder in iCloud Drive") {
                        store.setFolderDirectly(defaultTeachingFolder)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Create & open Teaching folder in iCloud Drive") {
                        do {
                            try FileManager.default.createDirectory(
                                at: defaultTeachingFolder,
                                withIntermediateDirectories: true
                            )
                            store.setFolderDirectly(defaultTeachingFolder)
                        } catch {
                            store.errorMessage = "Could not create folder: \(error.localizedDescription)"
                        }
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                }
                Button("Pick a different folder…") {
                    store.pickFolder()
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            .padding(.top, 8)

            VStack(alignment: .leading, spacing: 6) {
                Text("How it's organized")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Text("""
                Teaching/
                ├── year-9/
                │   └── forces/
                │       └── 2026-09-05-intro/
                │           ├── lesson.md
                │           ├── slides.pptx
                │           └── worksheet.pdf
                └── year-10/
                    └── …
                """)
                .font(.system(.caption, design: .monospaced))
                .padding(12)
                .background(Color(NSColor.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))

                Text("Each lesson is a folder with a `lesson.md` plan plus any resources (PowerPoint, PDF, images). Siblings of `lesson.md` appear in the detail panel and open in their default app on click.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 440)
                    .padding(.top, 4)
            }
            .padding(.top, 20)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
