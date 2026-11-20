import SwiftUI

struct MainView: View {
    @EnvironmentObject var store: EntryStore
    /// When set, the main pane shows LessonView instead of the calendar.
    let openedLesson: Entry?
    /// A single click on any lesson calls this.
    let onOpenLesson: (Entry) -> Void
    /// LessonView's Back button / Esc calls this.
    let onCloseLesson: () -> Void
    /// Opens the EntryEditor sheet — now triggered from LessonView's Edit button.
    let onEdit: (Entry) -> Void
    let onCreate: (Date) -> Void
    let onOpenSettings: () -> Void
    @State private var calendarKeyMonitor: Any? = nil

    var body: some View {
        VStack(spacing: 0) {
            Toolbar(onCreate: onCreate, onOpenSettings: onOpenSettings)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(NSColor.windowBackgroundColor))
            Divider()
            if let opened = openedLesson {
                // Single-lesson full-pane view
                LessonView(
                    entry: resolveFresh(opened),
                    onOpenLesson: onOpenLesson,
                    onEdit: onEdit,
                    onClose: onCloseLesson
                )
                .onAppear { removeCalendarMonitor() }   // LessonView installs its own
            } else {
                HStack(spacing: 0) {
                    if store.showRequirementsPanel {
                        RequirementsPanel(onEdit: onOpenLesson)
                            .frame(width: 340)
                        Divider()
                    }
                    Group {
                        switch store.view {
                        case .month:
                            MonthView(onEdit: onOpenLesson, onCreate: onCreate)
                        case .week:
                            WeekView(onEdit: onOpenLesson, onCreate: onCreate)
                        case .timeline:
                            TimelineView(onEdit: onOpenLesson)
                        case .classView:
                            ClassView(onEdit: onOpenLesson)
                        case .year:
                            YearView()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // DetailPanel removed — single-click now opens the full LessonView,
                    // which shows everything the sidebar preview used to.
                    if store.showHoldingPen {
                        Divider()
                        HoldingPenPanel(onOpenLesson: onOpenLesson)
                    }
                }
                .onAppear { installCalendarMonitor() }
                .onDisappear { removeCalendarMonitor() }
            }
        }
    }

    /// After a bump/pull/edit, the entry's folder may have been renamed and
    /// its `id` reissued. Pick up the freshest copy from the store by url;
    /// fall back to whatever we had.
    private func resolveFresh(_ entry: Entry) -> Entry {
        if let fresh = store.entries.first(where: { $0.id == entry.id }) { return fresh }
        if let fresh = store.entries.first(where: { $0.url == entry.url }) { return fresh }
        return entry
    }

    // MARK: - Calendar-view keyboard monitor
    //
    // Installed while no lesson is open. Handles navigation and quick open.
    //    ← / →   shift anchor by one period
    //    T       jump to today
    //    Return  open LessonView for the first lesson on the selected date
    // Keys pass through when a text responder is active, so typing in sheets
    // and editors is unaffected.
    private func installCalendarMonitor() {
        if calendarKeyMonitor != nil { return }
        calendarKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if let responder = NSApp.keyWindow?.firstResponder,
               responder is NSTextView || responder is NSText {
                return event
            }
            // Only act when the main window is key — not when a sheet is up
            if NSApp.keyWindow?.sheets.isEmpty == false { return event }

            // Strip auxiliary flags (arrow keys set .function; numeric pad sets
            // .numericPad) so our "no modifiers" check matches what the user held.
            let mods = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .subtracting([.function, .numericPad, .capsLock, .help])
            guard mods.isEmpty else { return event }

            switch event.keyCode {
            case 123:  // ← previous period
                shiftViewByPeriod(-1); return nil
            case 124:  // → next period
                shiftViewByPeriod(1);  return nil
            case 17:   // T
                store.selectedDate = DateUtil.startOfDay(Date())
                store.weekAnchor = Date()
                store.displayedMonth = Date()
                return nil
            case 36, 76:  // return / enter
                if let first = store.entries
                    .filter({ Calendar.current.isDate($0.date, inSameDayAs: store.selectedDate) })
                    .sorted(by: { $0.date < $1.date })
                    .first {
                    onOpenLesson(first)
                    return nil
                }
            default: break
            }
            return event
        }
    }

    private func removeCalendarMonitor() {
        if let m = calendarKeyMonitor {
            NSEvent.removeMonitor(m)
            calendarKeyMonitor = nil
        }
    }

    private func shiftViewByPeriod(_ delta: Int) {
        let cal = Calendar.current
        switch store.view {
        case .month:
            if let d = cal.date(byAdding: .month, value: delta, to: store.displayedMonth) {
                store.displayedMonth = d
            }
        case .week:
            if let d = cal.date(byAdding: .day, value: delta * 7, to: store.weekAnchor) {
                store.weekAnchor = d
            }
        case .timeline, .classView:
            if let d = cal.date(byAdding: .day, value: delta, to: store.selectedDate) {
                store.selectedDate = DateUtil.startOfDay(d)
            }
        case .year:
            // Year view: scroll to next/previous year
            if let d = cal.date(byAdding: .year, value: delta, to: store.displayedMonth) {
                store.displayedMonth = d
            }
        }
    }
}

struct Toolbar: View {
    @EnvironmentObject var store: EntryStore
    @EnvironmentObject var calendarSync: CalendarSync
    let onCreate: (Date) -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Picker("View", selection: $store.view) {
                Text("Calendar").tag(EntryStore.ViewMode.month)
                Text("Week").tag(EntryStore.ViewMode.week)
                Text("Timeline").tag(EntryStore.ViewMode.timeline)
                Text("Class").tag(EntryStore.ViewMode.classView)
                Text("Year").tag(EntryStore.ViewMode.year)
            }
            .pickerStyle(.segmented)
            .fixedSize()

            // Tag filter
            Menu(store.filterTag ?? "All entries") {
                Button("All entries") { store.filterTag = nil }
                Divider()
                ForEach(store.allTagsWithCounts, id: \.0) { tag, count in
                    Button("\(tag) (\(count))") { store.filterTag = tag }
                }
            }
            .frame(maxWidth: 160)

            // Requirements toggle
            Toggle(isOn: $store.showRequirementsPanel) {
                Label("Requirements", systemImage: "checklist")
            }
            .toggleStyle(.button)
            .controlSize(.regular)

            // Holding Pen toggle
            Toggle(isOn: $store.showHoldingPen) {
                Label(
                    "Holding Pen\(store.parkedEntries.isEmpty ? "" : "  (\(store.parkedEntries.count))")",
                    systemImage: "tray"
                )
            }
            .toggleStyle(.button)
            .controlSize(.regular)
            .help("Park lessons out of the schedule (⌘⇧H). Drag onto a day to reschedule.")

            Spacer()

            if let folder = store.folderURL {
                Text(folder.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Button {
                onCreate(store.selectedDate)
            } label: {
                Label("New entry", systemImage: "plus")
            }
            .keyboardShortcut("n", modifiers: .command)

            Button { store.reload() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh")

            Button { store.pickFolder() } label: {
                Image(systemName: "folder")
            }
            .help("Change folder")

            // Calendar-sync indicator + settings
            Button { onOpenSettings() } label: {
                HStack(spacing: 4) {
                    if calendarSync.isEnabled {
                        Image(systemName: "calendar.badge.checkmark")
                            .foregroundStyle(.green)
                    } else {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .help(calendarSync.isEnabled ? "Settings · Calendar sync enabled" : "Settings")
            .keyboardShortcut(",", modifiers: .command)
        }
    }
}
