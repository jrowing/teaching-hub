import SwiftUI
import AppKit

/// "Post to Google Classroom" for one lesson. Only the lesson's `## Students` section
/// (editable here before posting) and the resource files you tick are sent.
struct ClassroomPushSheet: View {
    let entry: Entry
    @EnvironmentObject var store: EntryStore
    @EnvironmentObject var client: ClassroomClient
    @Environment(\.dismiss) private var dismiss

    private enum WhenChoice: String, CaseIterable, Identifiable {
        case draft = "Save as draft"
        case now = "Post now"
        case schedule = "Schedule"
        var id: String { rawValue }
    }

    @State private var courses: [ClassroomCourse] = []
    @State private var courseID: String = ""
    @State private var topics: [ClassroomTopic] = []
    @State private var topicID: String = ""     // "" = "No topic"
    @State private var loadingTopics = false
    @State private var showingNewTopicSheet = false
    @State private var newTopicName: String = ""
    @State private var creatingTopic = false
    @State private var kind: ClassroomKind = .material
    @State private var whenChoice: WhenChoice = .draft
    @State private var scheduleDate: Date = Date().addingTimeInterval(3600)
    @State private var text: String = ""
    @State private var attachIDs: Set<String> = []
    @State private var loadingCourses = false
    @State private var working = false
    @State private var status: String?
    @State private var errorText: String?
    @State private var didSetup = false

    private var attachable: [Resource] {
        entry.resources.filter { r in
            let name = r.name.lowercased()
            return !name.hasPrefix(".") && name != "lesson.md"
        }
    }

    private var previousPostID: String? { entry.frontMatter["classroom_post"] }
    private var previousCourseID: String? { entry.frontMatter["classroom_course"] }
    private var previousKind: ClassroomKind? {
        entry.frontMatter["classroom_kind"].flatMap { ClassroomKind(rawValue: $0) }
    }
    private var previousTopicID: String? { entry.frontMatter["classroom_topic"] }

    private var courseKey: String { "Classroom.course.\(entry.classSlug ?? "none")" }
    private var topicKey: String {
        "Classroom.topic.\(entry.classSlug ?? "none").\(courseID)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if !client.isSignedIn {
                signedOutView
            } else {
                form
            }
        }
        .frame(width: 580, height: 700)
        .onAppear(perform: setup)
        .task(id: client.isSignedIn) { await loadCourses() }
        .task(id: courseID) { await loadTopics() }
        .sheet(isPresented: $showingNewTopicSheet) { newTopicSheet }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Post to Google Classroom").font(.title3).fontWeight(.semibold)
                Text(entry.title).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(20)
    }

    private var signedOutView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 34)).foregroundStyle(.tertiary)
            if client.isConfigured {
                Text("Sign in with your Google account to continue.")
                Button("Sign in to Google") { Task { await client.signIn() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(client.isBusy)
            } else {
                Text("Add your Google client ID and secret in Settings (⌘,) → Google Classroom first.")
                    .multilineTextAlignment(.center)
            }
            if let e = client.lastError {
                Text(e).font(.system(size: 11)).foregroundStyle(.red).padding(.horizontal, 30)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Form

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let postID = previousPostID {
                    previouslyPostedBanner(postID)
                }

                // Course
                VStack(alignment: .leading, spacing: 4) {
                    label("Course")
                    if loadingCourses {
                        ProgressView().controlSize(.small)
                    } else if courses.isEmpty {
                        Text("No active courses found where you are a teacher.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    } else {
                        Picker("", selection: $courseID) {
                            Text("Choose a course…").tag("")
                            ForEach(courses) { Text($0.displayName).tag($0.id) }
                        }
                        .labelsHidden()
                    }
                }

                // Topic (materials only — announcements aren't topic-scoped)
                if kind.supportsTopics {
                    topicPicker
                }

                // Kind + timing
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 4) {
                        label("Post as")
                        Picker("", selection: $kind) {
                            ForEach(ClassroomKind.allCases) { Text($0.label).tag($0) }
                        }
                        .labelsHidden().pickerStyle(.segmented).frame(width: 200)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        label("When")
                        Picker("", selection: $whenChoice) {
                            ForEach(WhenChoice.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden().pickerStyle(.segmented).frame(width: 260)
                        if whenChoice == .schedule {
                            DatePicker("", selection: $scheduleDate, in: Date()...)
                                .labelsHidden()
                        }
                    }
                }

                // Student text
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        label("Text students will see")
                        Spacer()
                        Text("from the ## Students section — edits here don't change lesson.md")
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    TextEditor(text: $text)
                        .font(.system(size: 12))
                        .frame(height: 150)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.3)))
                    if ClassroomText.studentsSection(in: entry.bodyFull) == nil {
                        Text("This lesson has no “## Students” section, so nothing is pre-filled. Add one to lesson.md, or type the text here.")
                            .font(.system(size: 11)).foregroundStyle(.orange)
                    }
                }

                // Attachments
                VStack(alignment: .leading, spacing: 6) {
                    label("Attach files from this lesson")
                    if attachable.isEmpty {
                        Text("This lesson folder has no other files.")
                            .font(.system(size: 12)).foregroundStyle(.tertiary)
                    } else {
                        ForEach(attachable) { r in
                            Toggle(isOn: Binding(
                                get: { attachIDs.contains(r.id) },
                                set: { on in
                                    if on { attachIDs.insert(r.id) } else { attachIDs.remove(r.id) }
                                }
                            )) {
                                HStack(spacing: 6) {
                                    Image(systemName: r.symbolName).foregroundStyle(.secondary)
                                    Text(r.name).font(.system(size: 12))
                                    Text(ByteCountFormatter.string(fromByteCount: r.size, countStyle: .file))
                                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                        Text("Nothing is attached unless you tick it. Ticked files are uploaded to your Google Drive and shared with the class as view-only.")
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                }

                if let status {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(status).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                if let errorText {
                    Text(errorText)
                        .font(.system(size: 11)).foregroundStyle(.red)
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }

                HStack {
                    Spacer()
                    Button(previousPostID == nil ? postButtonTitle : "\(postButtonTitle) as new post") {
                        Task { await submit() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canPost)
                }
            }
            .padding(20)
        }
    }

    // MARK: Topic picker

    @ViewBuilder
    private var topicPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                label("Topic")
                Spacer()
                if loadingTopics {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                }
                Button {
                    newTopicName = ""
                    showingNewTopicSheet = true
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "plus.circle")
                        Text("New topic…")
                    }
                    .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
                .disabled(courseID.isEmpty)
            }
            Picker("", selection: $topicID) {
                Text("— no topic —").tag("")
                ForEach(topics) { Text($0.name).tag($0.id) }
            }
            .labelsHidden()
            .disabled(courseID.isEmpty || loadingTopics)
            if !courseID.isEmpty, topics.isEmpty, !loadingTopics {
                Text("This course has no topics yet. Click “New topic…” to create one.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
    }

    private var newTopicSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New topic")
                .font(.headline)
            Text("Topics group materials inside a Classroom course. The new topic appears in the dropdown once created.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Topic name", text: $newTopicName)
                .textFieldStyle(.roundedBorder)
            HStack {
                if creatingTopic { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") {
                    showingNewTopicSheet = false
                }
                .keyboardShortcut(.cancelAction)
                Button("Create") {
                    Task { await createTopic() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(newTopicName.trimmingCharacters(in: .whitespaces).isEmpty || creatingTopic)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private var postButtonTitle: String {
        switch whenChoice {
        case .draft: return "Save draft in Classroom"
        case .now: return "Post now"
        case .schedule: return "Schedule post"
        }
    }

    private var canPost: Bool {
        !working && !courseID.isEmpty
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func label(_ s: String) -> some View {
        Text(s).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
    }

    private func previouslyPostedBanner(_ postID: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Already posted to Classroom", systemImage: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(.green)
            Text("You can update the wording of that post. Classroom doesn't allow changing attachments afterwards, so use “as new post” below if the files changed.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Button("Update text of existing post") { Task { await updateExisting(postID) } }
                .disabled(working || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || (previousCourseID ?? "").isEmpty)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: Actions

    private func setup() {
        guard !didSetup else { return }
        didSetup = true
        text = ClassroomText.studentsSection(in: entry.bodyFull).map(ClassroomText.plain) ?? ""
        if let k = previousKind { kind = k }
        courseID = previousCourseID
            ?? UserDefaults.standard.string(forKey: courseKey)
            ?? ""
        // Default a schedule to 07:00 on the lesson's day if that is still in the future.
        let morning = Calendar.current.date(bySettingHour: 7, minute: 0, second: 0, of: entry.date)
        if let morning, morning > Date() { scheduleDate = morning }
    }

    private func loadCourses() async {
        guard client.isSignedIn else { return }
        loadingCourses = true
        defer { loadingCourses = false }
        do {
            courses = try await client.courses()
            if !courseID.isEmpty, !courses.contains(where: { $0.id == courseID }) { courseID = "" }
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func loadTopics() async {
        topics = []
        guard client.isSignedIn, !courseID.isEmpty else {
            topicID = ""
            return
        }
        loadingTopics = true
        defer { loadingTopics = false }
        do {
            let fetched = try await client.topics(courseID: courseID)
            topics = fetched
            // Prefer the topic this lesson was previously posted to on this course,
            // then the last topic the user picked for this (class, course) pair,
            // then no topic.
            let preferred: String? = {
                if let prev = previousTopicID, fetched.contains(where: { $0.id == prev }) { return prev }
                if let saved = UserDefaults.standard.string(forKey: topicKey),
                   fetched.contains(where: { $0.id == saved }) { return saved }
                return nil
            }()
            topicID = preferred ?? ""
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func createTopic() async {
        let name = newTopicName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !courseID.isEmpty else { return }
        creatingTopic = true
        defer { creatingTopic = false }
        do {
            let created = try await client.createTopic(courseID: courseID, name: name)
            topics.append(created)
            topics.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            topicID = created.id
            showingNewTopicSheet = false
        } catch {
            errorText = error.localizedDescription
        }
    }

    private var timing: ClassroomTiming {
        switch whenChoice {
        case .draft: return .draft
        case .now: return .now
        case .schedule: return .scheduled(scheduleDate)
        }
    }

    private func submit() async {
        working = true
        errorText = nil
        defer { working = false; status = nil }
        do {
            var driveIDs: [String] = []
            let files = attachable.filter { attachIDs.contains($0.id) }
            for (i, r) in files.enumerated() {
                status = "Uploading \(r.name) (\(i + 1) of \(files.count))…"
                driveIDs.append(try await client.uploadToDrive(r.url))
            }
            status = "Creating post…"
            let effectiveTopic: String? = kind.supportsTopics
                ? (topicID.isEmpty ? nil : topicID)
                : nil
            let id = try await client.post(
                kind: kind,
                courseID: courseID,
                title: entry.title,
                text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                timing: timing,
                driveIDs: driveIDs,
                topicID: effectiveTopic
            )
            UserDefaults.standard.set(courseID, forKey: courseKey)
            if let effectiveTopic {
                UserDefaults.standard.set(effectiveTopic, forKey: topicKey)
            }
            var fm: [String: String] = [
                "classroom_post": id,
                "classroom_course": courseID,
                "classroom_kind": kind.rawValue
            ]
            if let effectiveTopic { fm["classroom_topic"] = effectiveTopic }
            else { fm["classroom_topic"] = "" }   // clears any previous value
            try store.setFrontMatter(entry, set: fm)
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func updateExisting(_ postID: String) async {
        guard let course = previousCourseID, !course.isEmpty else { return }
        working = true
        errorText = nil
        status = "Updating post…"
        defer { working = false; status = nil }
        do {
            try await client.updateText(
                kind: previousKind ?? kind,
                courseID: course,
                postID: postID,
                title: entry.title,
                text: text.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
