import SwiftUI
import AppKit

@main
struct TeachingHubApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup("Teaching Hub") {
            ContentView()
                .environmentObject(appDelegate.store)
                .environmentObject(appDelegate)
                .environmentObject(appDelegate.calendarSync)
                .environmentObject(appDelegate.classroom)
                .frame(minWidth: 1100, minHeight: 700)
                .onReceive(NotificationCenter.default.publisher(for: .openEntry)) { note in
                    if let id = note.object as? String,
                       let entry = appDelegate.store.entries.first(where: { $0.id == id }) {
                        appDelegate.entryToOpen = entry
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            // File menu
            CommandGroup(replacing: .newItem) {
                Button("New Entry…") {
                    appDelegate.requestNewEntry()
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(after: .newItem) {
                Button("Open Folder…") {
                    appDelegate.store.pickFolder()
                }
                .keyboardShortcut("o", modifiers: .command)
                Divider()
                Button("Reload") {
                    appDelegate.store.reload()
                }
                .keyboardShortcut("r", modifiers: .command)
                Button("Disconnect Folder") {
                    appDelegate.store.disconnect()
                }
                Divider()
                // Export → … submenu
                Menu("Export") {
                    Button("Lesson as PDF…") {
                        appDelegate.exportLessonPDF()
                    }
                    .keyboardShortcut("e", modifiers: [.command])
                    Button("Day as PDF…") {
                        appDelegate.exportDayPDF()
                    }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    Button("Week as PDF…") {
                        appDelegate.exportWeekPDF()
                    }
                    .keyboardShortcut("e", modifiers: [.command, .option])
                    Button("Week Overview as PDF…") {
                        appDelegate.exportWeekOverviewPDF()
                    }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                    Button("Technician Sheet as PDF…") {
                        appDelegate.exportTechnicianPDF()
                    }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                    Button("Topic as PDF…") {
                        appDelegate.exportTopicPDF()
                    }
                    .keyboardShortcut("e", modifiers: [.command, .control])
                }
            }
            // Settings — mac standard ⌘,
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    appDelegate.settingsRequested = true
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            // Navigate menu
            CommandMenu("Navigate") {
                Button("Today") {
                    appDelegate.store.selectedDate = DateUtil.startOfDay(Date())
                    appDelegate.store.displayedMonth = Date()
                    appDelegate.store.weekAnchor = Date()
                    appDelegate.store.requirementsWeekAnchor = Date()
                }
                .keyboardShortcut("t", modifiers: .command)
                Divider()
                Button("Month View") {
                    appDelegate.store.view = .month
                }
                .keyboardShortcut("1", modifiers: .command)
                Button("Week View") {
                    appDelegate.store.view = .week
                }
                .keyboardShortcut("2", modifiers: .command)
                Button("Timeline View") {
                    appDelegate.store.view = .timeline
                }
                .keyboardShortcut("3", modifiers: .command)
                Button("Class View") {
                    appDelegate.store.view = .classView
                }
                .keyboardShortcut("4", modifiers: .command)
                Button("Year View") {
                    appDelegate.store.view = .year
                }
                .keyboardShortcut("5", modifiers: .command)
                Divider()
                Button("Toggle Requirements Panel") {
                    appDelegate.store.showRequirementsPanel.toggle()
                }
                .keyboardShortcut("b", modifiers: .command)
                Button("Toggle Holding Pen") {
                    appDelegate.store.showHoldingPen.toggle()
                }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            }
        }
    }
}

/// AppDelegate hosts the long-lived store + status-bar controller.
/// SwiftUI's `App` body is recreated frequently, so anything that needs to outlive
/// view rebuilds (the tray, the store, file watching) lives here.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let store = EntryStore()
    lazy var calendarSync: CalendarSync = CalendarSync(store: store)
    lazy var classroom: ClassroomClient = ClassroomClient()
    var statusBar: StatusBarController?

    /// Entry the user clicked from the tray menu — read & cleared by ContentView.
    @Published var entryToOpen: Entry? = nil

    /// Set to true to ask MainView to open the create-entry sheet for the
    /// currently-selected date (driven by the File → New Entry menu).
    @Published var newEntryRequested: Bool = false

    /// Set to true to ask MainView to open the Settings sheet (Settings menu or ⌘,).
    @Published var settingsRequested: Bool = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // SPM-built executables don't get a default activation policy.
        // Setting .regular makes the app behave like a normal Mac app:
        // shows up in the dock, has a menu bar, can be foregrounded.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        statusBar = StatusBarController(store: store)
        // Touch calendarSync so its Combine subscription to entries is active
        // from launch. If the user had sync enabled previously, the first entries-load
        // will trigger a background sync. Touch classroom so saved client-id /
        // refresh-token state is loaded before any view needs it.
        _ = calendarSync
        _ = classroom
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep the app alive in the menu bar even when the window is closed.
        return false
    }

    func requestNewEntry() {
        // Bring window to the front, then signal MainView to open the editor sheet.
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
        }
        newEntryRequested = true
    }

    // MARK: - PDF export menu actions

    /// The lesson these actions operate on. In order: the editor's currently
    /// open entry; else the first entry on the selected date; else the next
    /// upcoming entry from today.
    private func contextLesson() -> Entry? {
        if let e = entryToOpen { return e }
        let sel = store.selectedDate
        if let same = store.entries.first(where: { Calendar.current.isDate($0.date, inSameDayAs: sel) }) {
            return same
        }
        let now = Date()
        return store.entries.first(where: { $0.date >= now })
    }

    func exportLessonPDF() {
        guard let entry = contextLesson() else {
            NSAlert.informational(title: "No lesson selected",
                                  message: "Open a lesson, or click one in a day with lessons, then try again.")
            return
        }
        PDFExport.exportLesson(entry)
    }

    func exportDayPDF() {
        PDFExport.exportDay(store.selectedDate, entries: store.entries)
    }

    func exportWeekPDF() {
        PDFExport.exportWeek(anchoredAt: store.weekAnchor, entries: store.entries)
    }

    func exportWeekOverviewPDF() {
        PDFExport.exportWeekOverview(anchoredAt: store.weekAnchor, entries: store.entries)
    }

    func exportTechnicianPDF() {
        PDFExport.exportTechnician(
            anchoredAt: store.weekAnchor,
            entries: store.entries,
            classes: store.classes
        )
    }

    func exportTopicPDF() {
        guard let entry = contextLesson() else {
            NSAlert.informational(title: "No topic selected",
                                  message: "Open a lesson from the topic you want to export, then try again.")
            return
        }
        let chapterURL = entry.folderURL.deletingLastPathComponent()
        let chapterSlug = chapterURL.lastPathComponent
        let topicEntries = store.entries.filter {
            $0.folderURL.deletingLastPathComponent().lastPathComponent == chapterSlug
        }
        let niceTitle = chapterSlug
            .replacingOccurrences(of: #"^[a-z]\d+-"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "-", with: " ")
            .capitalized
        PDFExport.exportTopic(title: niceTitle, entries: topicEntries)
    }
}

private extension NSAlert {
    static func informational(title: String, message: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.alertStyle = .informational
        a.addButton(withTitle: "OK")
        a.runModal()
    }
}
