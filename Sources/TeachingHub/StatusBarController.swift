import AppKit
import Combine
import SwiftUI

/// Manages the menu-bar status item showing today's entries.
/// Subscribes to EntryStore and rebuilds the menu whenever entries change.
@MainActor
final class StatusBarController: NSObject {
    private var statusItem: NSStatusItem!
    private var cancellables: Set<AnyCancellable> = []
    private weak var store: EntryStore?

    init(store: EntryStore) {
        super.init()
        self.store = store
        setupItem()
        rebuild()
        store.$entries
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.rebuild()
                }
            }
            .store(in: &cancellables)
        // Event-driven day rollover (no polling, so no battery cost):
        //  - NSCalendarDayChanged: macOS posts this at midnight, and after a
        //    wake or clock/timezone change if the date has moved on
        //  - didWake: belt and braces after the Mac sleeps overnight
        NotificationCenter.default.addObserver(
            forName: .NSCalendarDayChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.dayMayHaveChanged() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.dayMayHaveChanged() }
        }
    }

    /// The day we last built the menu for.
    private var lastDay = Calendar.current.startOfDay(for: Date())

    private func dayMayHaveChanged() {
        let today = Calendar.current.startOfDay(for: Date())
        guard today != lastDay else { return }
        let previous = lastDay
        lastDay = today
        // If the main window was still sitting on "yesterday", follow to today.
        // If the user had navigated elsewhere, leave their position alone.
        if let store, Calendar.current.isDate(store.selectedDate, inSameDayAs: previous) {
            store.selectedDate = today
            store.weekAnchor = today
            store.displayedMonth = today
        }
        rebuild()
    }

    private func setupItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let img = NSImage(systemSymbolName: "calendar", accessibilityDescription: "Teaching Hub")
            img?.isTemplate = true
            button.image = img
            button.imagePosition = .imageLeft
        }
    }

    private func rebuild() {
        guard let store else { return }
        let menu = NSMenu()

        let todayLabel = todayString()
        let header = NSMenuItem(title: todayLabel, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        let todays = store.entries(on: Date())
        if todays.isEmpty {
            let none = NSMenuItem(title: "No entries today", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        } else {
            for entry in todays.prefix(12) {
                let prefix: String = entry.hasTime
                    ? "  \(DateUtil.formatTime(entry.date))   "
                    : "    ·    "
                let item = NSMenuItem(
                    title: "\(prefix)\(entry.title)",
                    action: #selector(openEntry(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = entry.id
                menu.addItem(item)
            }
            if todays.count > 12 {
                let more = NSMenuItem(title: "… and \(todays.count - 12) more", action: nil, keyEquivalent: "")
                more.isEnabled = false
                menu.addItem(more)
            }
        }
        menu.addItem(NSMenuItem.separator())
        let openApp = NSMenuItem(title: "Open Teaching Hub", action: #selector(openApp), keyEquivalent: "")
        openApp.target = self
        menu.addItem(openApp)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu

        // Show count badge in title
        if let button = statusItem.button {
            let count = todays.count
            button.title = count > 0 ? " \(count)" : ""
        }
    }

    private func todayString() -> String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMMM d"
        return f.string(from: Date())
    }

    @objc private func openApp() {
        if let store {
            store.selectedDate = DateUtil.startOfDay(Date())
            store.displayedMonth = Date()
        }
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func openEntry(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let store,
              let entry = store.entries.first(where: { $0.id == id }) else { return }
        store.selectedDate = DateUtil.startOfDay(entry.date)
        store.displayedMonth = entry.date
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
        }
        // Notify the app to open this entry. We post a Notification so SwiftUI can pick it up.
        NotificationCenter.default.post(name: .openEntry, object: entry.id)
    }
}

extension Notification.Name {
    static let openEntry = Notification.Name("TeachHub.openEntry")
}
