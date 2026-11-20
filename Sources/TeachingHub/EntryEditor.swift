import SwiftUI

struct EntryEditor: View {
    enum Mode {
        case create(Date)
        case edit(Entry)
    }

    let mode: Mode
    let onClose: () -> Void

    @EnvironmentObject var store: EntryStore

    @State private var title: String = ""
    @State private var date: Date = Date()
    @State private var includeTime: Bool = false
    @State private var endTime: Date = Date()
    @State private var includeEndTime: Bool = false
    @State private var tagsString: String = ""
    @State private var bodyText: String = ""
    @State private var requirementsString: String = ""
    @State private var subfolder: String = ""
    @State private var repeatWeekly: Bool = false
    @State private var repeatUntil: Date = Calendar.current.date(byAdding: .month, value: 3, to: Date()) ?? Date()
    @State private var errorMessage: String? = nil
    @State private var isWorking: Bool = false
    @State private var showDeleteConfirm: Bool = false

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isEditing ? "Edit entry" : "New entry")
                    .font(.title3)
                    .fontWeight(.semibold)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if case .edit(let entry) = mode {
                        Group {
                            Text("File")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(entry.relpath)
                                .font(.system(.caption, design: .monospaced))
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(NSColor.controlBackgroundColor))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }

                    field("Title") {
                        TextField("Meeting notes, journal, etc.", text: $title)
                            .textFieldStyle(.roundedBorder)
                    }

                    HStack(spacing: 12) {
                        field("Date") {
                            DatePicker("", selection: $date, displayedComponents: [.date])
                                .labelsHidden()
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Start time").font(.caption).foregroundStyle(.secondary)
                                Toggle("", isOn: $includeTime)
                                    .toggleStyle(.switch)
                                    .controlSize(.small)
                                    .labelsHidden()
                            }
                            DatePicker("", selection: $date, displayedComponents: [.hourAndMinute])
                                .labelsHidden()
                                .disabled(!includeTime)
                                .opacity(includeTime ? 1.0 : 0.4)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("End time").font(.caption).foregroundStyle(.secondary)
                                Toggle("", isOn: $includeEndTime)
                                    .toggleStyle(.switch)
                                    .controlSize(.small)
                                    .labelsHidden()
                            }
                            DatePicker("", selection: $endTime, displayedComponents: [.hourAndMinute])
                                .labelsHidden()
                                .disabled(!includeTime || !includeEndTime)
                                .opacity((includeTime && includeEndTime) ? 1.0 : 0.4)
                        }
                    }

                    field("Tags (comma-separated)") {
                        TextField("work, meeting", text: $tagsString)
                            .textFieldStyle(.roundedBorder)
                    }

                    if !isEditing {
                        Toggle(isOn: $repeatWeekly) {
                            Text("Repeat weekly until")
                        }
                        if repeatWeekly {
                            HStack {
                                DatePicker("", selection: $repeatUntil, displayedComponents: [.date])
                                    .labelsHidden()
                                Text(occurrencesString)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        field("Folder") {
                            Picker("", selection: $subfolder) {
                                ForEach(store.subfolders(), id: \.self) { sub in
                                    Text(sub.isEmpty ? "(root)" : sub).tag(sub)
                                }
                            }
                            .labelsHidden()
                        }
                    }

                    field("Body (markdown)") {
                        TextEditor(text: $bodyText)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 140)
                            .padding(4)
                            .background(Color(NSColor.controlBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }

                    field("Requirements (one per line)") {
                        TextEditor(text: $requirementsString)
                            .font(.system(.caption, design: .monospaced))
                            .frame(minHeight: 80)
                            .padding(4)
                            .background(Color(NSColor.controlBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }

                    if let err = errorMessage {
                        Text(err)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
                .padding(20)
            }

            Divider()
            HStack {
                if isEditing {
                    Button("Delete", role: .destructive) {
                        showDeleteConfirm = true
                    }
                    .confirmationDialog("Delete this entry?",
                                        isPresented: $showDeleteConfirm,
                                        titleVisibility: .visible) {
                        Button("Delete", role: .destructive) { performDelete() }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        if case .edit(let entry) = mode {
                            Text("This will permanently delete \(entry.relpath).")
                        }
                    }
                }
                Spacer()
                Button("Cancel") { onClose() }
                    .keyboardShortcut(.cancelAction)
                Button(isEditing ? "Save" : "Create") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(isWorking || title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(16)
        }
        .frame(minWidth: 540, idealWidth: 580, minHeight: 600, idealHeight: 700)
        .onAppear { populate() }
    }

    @ViewBuilder
    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }

    private func populate() {
        switch mode {
        case .create(let initialDate):
            self.date = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: initialDate) ?? initialDate
            self.endTime = Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: initialDate) ?? initialDate
            self.includeTime = false
            self.includeEndTime = false
        case .edit(let entry):
            self.title = entry.title
            self.date = entry.date
            self.includeTime = entry.hasTime
            if let end = entry.endDate {
                self.endTime = end
                self.includeEndTime = true
            } else {
                self.endTime = Calendar.current.date(byAdding: .hour, value: 1, to: entry.date) ?? entry.date
                self.includeEndTime = false
            }
            self.tagsString = entry.tags.joined(separator: ", ")
            self.bodyText = entry.body
            self.requirementsString = entry.requirements.joined(separator: "\n")
        }
    }

    private var occurrencesString: String {
        let cal = Calendar.current
        let weekdayName = DateFormatter().weekdaySymbols[cal.component(.weekday, from: date) - 1]
        var count = 0
        var cursor = date
        while cursor <= repeatUntil && count < 520 {
            count += 1
            cursor = cal.date(byAdding: .day, value: 7, to: cursor) ?? cursor
        }
        return "\(count) occurrence\(count == 1 ? "" : "s") · every \(weekdayName)"
    }

    private func submit() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        guard !trimmedTitle.isEmpty else { return }

        let tags = tagsString
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let requirements = requirementsString
            .split(whereSeparator: \.isNewline)
            .map { line -> String in
                let s = line.trimmingCharacters(in: .whitespaces)
                let stripped = s.replacingOccurrences(of: #"^[-*+]\s+"#, with: "", options: .regularExpression)
                return stripped.replacingOccurrences(of: #"^\[\s*[ xX]?\s*\]\s*"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }

        // Compose the date with optional time
        var dateOut = date
        if !includeTime {
            dateOut = Calendar.current.startOfDay(for: date)
        }

        var endOut: Date? = nil
        if includeTime && includeEndTime {
            // Combine date's day + endTime's H:M
            let cal = Calendar.current
            let dayComps = cal.dateComponents([.year, .month, .day], from: date)
            let timeComps = cal.dateComponents([.hour, .minute], from: endTime)
            var combined = DateComponents()
            combined.year = dayComps.year
            combined.month = dayComps.month
            combined.day = dayComps.day
            combined.hour = timeComps.hour
            combined.minute = timeComps.minute
            if var e = cal.date(from: combined) {
                if e <= dateOut { e = cal.date(byAdding: .day, value: 1, to: e) ?? e }
                endOut = e
            }
        }

        isWorking = true
        defer { isWorking = false }
        do {
            switch mode {
            case .create:
                let until: Date? = repeatWeekly ? repeatUntil : nil
                _ = try store.createEntries(
                    title: trimmedTitle,
                    date: dateOut,
                    includeTime: includeTime,
                    endDate: endOut,
                    tags: tags,
                    body: bodyText,
                    requirements: requirements,
                    subfolder: subfolder.isEmpty ? nil : subfolder,
                    recurrenceUntil: until
                )
            case .edit(let entry):
                try store.updateEntry(
                    entry,
                    title: trimmedTitle,
                    date: dateOut,
                    includeTime: includeTime,
                    endDate: endOut,
                    tags: tags,
                    body: bodyText,
                    requirements: requirements
                )
            }
            onClose()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func performDelete() {
        guard case .edit(let entry) = mode else { return }
        do {
            try store.deleteEntry(entry)
            onClose()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
