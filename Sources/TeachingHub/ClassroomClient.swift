import Foundation
import AppKit
import Network
import CryptoKit
import Security
import UniformTypeIdentifiers

// MARK: - Student-facing text

/// Pulls the student-facing part out of a lesson and turns it into plain text for Classroom.
/// Only the `## Students` section of lesson.md ever leaves the app.
enum ClassroomText {
    /// Body text under a level-2 heading called "Students" (or "Student" / "For students"),
    /// up to the next heading of level 1 or 2. Nil when the lesson has no such section.
    static func studentsSection(in body: String) -> String? {
        let accepted: Set<String> = ["students", "student", "for students"]
        var collecting = false
        var out: [String] = []
        for line in body.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#") {
                let level = t.prefix(while: { $0 == "#" }).count
                let heading = t.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces).lowercased()
                if collecting && level <= 2 { break }
                if !collecting && level == 2 && accepted.contains(heading) {
                    collecting = true
                    continue
                }
            }
            if collecting { out.append(line) }
        }
        let text = out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Classroom doesn't render markdown, so tidy it into readable plain text.
    static func plain(_ markdown: String) -> String {
        var s = markdown
        let rules: [(String, String)] = [
            (#"\[([^\]]+)\]\(([^)]+)\)"#, "$1 ($2)"),     // [text](url) -> text (url)
            (#"(?m)^\s*#{1,6}\s*"#, ""),                    // heading hashes
            (#"(?m)^\s*[-*+]\s+"#, "• "),                   // bullets
            (#"\*\*(.+?)\*\*"#, "$1"),                      // bold
            (#"__(.+?)__"#, "$1"),
            (#"`([^`]*)`"#, "$1")                           // inline code
        ]
        for (pattern, template) in rules {
            s = s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Errors & models

enum ClassroomError: LocalizedError {
    case notConfigured
    case notSignedIn
    case auth(String)
    case http(Int, String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Add your Google client ID and secret in Settings → Google Classroom first."
        case .notSignedIn:
            return "Not signed in to Google. Sign in from Settings → Google Classroom."
        case .auth(let m):
            return "Google sign-in failed: \(m)"
        case .http(let code, let m):
            if code == 403 {
                return "Google refused (403): \(m). If this mentions access or policy, your school's Workspace admin may be blocking the app."
            }
            return "Google returned \(code): \(m)"
        case .timedOut:
            return "Sign-in timed out. Try again."
        }
    }
}

struct ClassroomCourse: Identifiable, Hashable {
    let id: String
    let name: String
    let section: String?
    var displayName: String { section.map { "\(name) — \($0)" } ?? name }
}

/// A Classroom "topic" — Google Classroom's way of grouping materials and
/// coursework posts inside a course. Announcements cannot be topic-scoped.
struct ClassroomTopic: Identifiable, Hashable {
    let id: String
    let name: String
}

enum ClassroomKind: String, CaseIterable, Identifiable {
    case announcement, material
    var id: String { rawValue }
    var label: String { self == .announcement ? "Announcement" : "Material" }
    /// Whether this kind of post can be filed under a topic.
    var supportsTopics: Bool { self == .material }
}

enum ClassroomTiming: Hashable {
    case draft
    case now
    case scheduled(Date)
}

// MARK: - Keychain

private enum Keychain {
    static let service = "com.teachinghub.app.classroom"

    private static func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func save(_ value: String, account: String) {
        let q = base(account)
        SecItemDelete(q as CFDictionary)
        var add = q
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    static func read(account: String) -> String? {
        var q = base(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        SecItemDelete(base(account) as CFDictionary)
    }
}

// MARK: - Loopback server for the OAuth redirect

/// Listens once on 127.0.0.1 for Google's redirect and hands back the query parameters.
private final class LoopbackServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "teachinghub.oauth.loopback")
    private let lock = NSLock()
    private var listener: NWListener?
    private var startCont: CheckedContinuation<UInt16, Error>?
    private var redirectCont: CheckedContinuation<[String: String], Error>?
    private var early: Result<[String: String], Error>?

    func start() async throws -> UInt16 {
        let l = try NWListener(using: .tcp)
        listener = l
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            lock.lock(); startCont = cont; lock.unlock()
            l.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    if let port = l.port?.rawValue { self.resumeStart(.success(port)) }
                case .failed(let err):
                    self.resumeStart(.failure(err))
                default:
                    break
                }
            }
            l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
            l.start(queue: queue)
        }
    }

    private func resumeStart(_ result: Result<UInt16, Error>) {
        lock.lock()
        let c = startCont
        startCont = nil
        lock.unlock()
        c?.resume(with: result)
    }

    func waitForRedirect() async throws -> [String: String] {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[String: String], Error>) in
            lock.lock()
            if let e = early {
                early = nil
                lock.unlock()
                cont.resume(with: e)
            } else {
                redirectCont = cont
                lock.unlock()
            }
        }
    }

    private func finish(_ result: Result<[String: String], Error>) {
        lock.lock()
        if let c = redirectCont {
            redirectCont = nil
            lock.unlock()
            c.resume(with: result)
        } else {
            if early == nil { early = result }
            lock.unlock()
        }
        listener?.cancel()
        listener = nil
    }

    func cancel() { finish(.failure(ClassroomError.timedOut)) }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self else { return }
            var params: [String: String] = [:]
            if let data, let text = String(data: data, encoding: .utf8),
               let firstLine = text.components(separatedBy: "\r\n").first {
                let parts = firstLine.split(separator: " ")
                if parts.count >= 2, let comps = URLComponents(string: "http://127.0.0.1" + parts[1]) {
                    for item in comps.queryItems ?? [] { params[item.name] = item.value ?? "" }
                }
            }
            let ok = params["code"] != nil || params["error"] != nil
            let html = ok
                ? "<html><body style='font-family:-apple-system;text-align:center;padding-top:80px'><h2>Teaching Hub is connected to Google</h2><p>You can close this tab.</p></body></html>"
                : "<html><body></body></html>"
            let response = "HTTP/1.1 \(ok ? "200 OK" : "404 Not Found")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
            conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in conn.cancel() })
            if ok { self.finish(.success(params)) }
        }
    }
}

// MARK: - Client

/// Talks to Google Classroom and Drive. Owned by AppDelegate and passed around as an environment object;
/// the refresh token lives in the Keychain.
@MainActor
final class ClassroomClient: ObservableObject {
    private enum Keys {
        static let clientID = "Classroom.clientID"
        static let clientSecret = "Classroom.clientSecret"
        static let uploads = "Classroom.driveUploads"
        static let refreshAccount = "refreshToken"
    }

    static let scopes = [
        "https://www.googleapis.com/auth/classroom.courses.readonly",
        "https://www.googleapis.com/auth/classroom.announcements",
        "https://www.googleapis.com/auth/classroom.courseworkmaterials",
        "https://www.googleapis.com/auth/classroom.topics",
        "https://www.googleapis.com/auth/drive.file"
    ]

    @Published var clientID: String {
        didSet { UserDefaults.standard.set(clientID, forKey: Keys.clientID) }
    }
    @Published var clientSecret: String {
        didSet { UserDefaults.standard.set(clientSecret, forKey: Keys.clientSecret) }
    }
    @Published private(set) var isSignedIn: Bool
    @Published private(set) var isBusy = false
    @Published var lastError: String?

    private var accessToken: String?
    private var accessExpiry: Date = .distantPast

    init() {
        clientID = UserDefaults.standard.string(forKey: Keys.clientID) ?? ""
        clientSecret = UserDefaults.standard.string(forKey: Keys.clientSecret) ?? ""
        isSignedIn = Keychain.read(account: Keys.refreshAccount) != nil
    }

    var isConfigured: Bool {
        !clientID.trimmingCharacters(in: .whitespaces).isEmpty &&
        !clientSecret.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: Sign in / out

    func signIn() async {
        guard isConfigured else { lastError = ClassroomError.notConfigured.errorDescription; return }
        isBusy = true
        lastError = nil
        defer { isBusy = false }
        let server = LoopbackServer()
        do {
            let verifier = Self.randomString(64)
            let challenge = Self.base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
            let state = Self.randomString(16)
            let port = try await server.start()
            let redirect = "http://127.0.0.1:\(port)"

            var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
            comps.queryItems = [
                .init(name: "client_id", value: clientID.trimmingCharacters(in: .whitespaces)),
                .init(name: "redirect_uri", value: redirect),
                .init(name: "response_type", value: "code"),
                .init(name: "scope", value: Self.scopes.joined(separator: " ")),
                .init(name: "code_challenge", value: challenge),
                .init(name: "code_challenge_method", value: "S256"),
                .init(name: "state", value: state),
                .init(name: "access_type", value: "offline"),
                .init(name: "prompt", value: "consent")
            ]
            NSWorkspace.shared.open(comps.url!)

            let timeout = Task {
                try? await Task.sleep(nanoseconds: 180_000_000_000)
                server.cancel()
            }
            let params = try await server.waitForRedirect()
            timeout.cancel()

            if let err = params["error"] { throw ClassroomError.auth(err) }
            guard params["state"] == state, let code = params["code"] else {
                throw ClassroomError.auth("unexpected response")
            }
            try await exchange(code: code, verifier: verifier, redirect: redirect)
        } catch {
            server.cancel()
            lastError = error.localizedDescription
        }
    }

    func signOut() {
        Keychain.delete(account: Keys.refreshAccount)
        accessToken = nil
        accessExpiry = .distantPast
        isSignedIn = false
    }

    private func exchange(code: String, verifier: String, redirect: String) async throws {
        let json = try await tokenRequest([
            "code": code,
            "client_id": clientID.trimmingCharacters(in: .whitespaces),
            "client_secret": clientSecret.trimmingCharacters(in: .whitespaces),
            "redirect_uri": redirect,
            "grant_type": "authorization_code",
            "code_verifier": verifier
        ])
        guard let access = json["access_token"] as? String else {
            throw ClassroomError.auth("no access token returned")
        }
        if let refresh = json["refresh_token"] as? String {
            Keychain.save(refresh, account: Keys.refreshAccount)
        }
        accessToken = access
        accessExpiry = Date().addingTimeInterval((json["expires_in"] as? Double) ?? 3000)
        isSignedIn = Keychain.read(account: Keys.refreshAccount) != nil
    }

    private func tokenRequest(_ form: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        req.httpBody = form.map { k, v in
            "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v)"
        }.joined(separator: "&").data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let desc = (json["error_description"] as? String) ?? (json["error"] as? String) ?? "HTTP \(http.statusCode)"
            throw ClassroomError.auth(desc)
        }
        return json
    }

    private func validAccessToken() async throws -> String {
        if let t = accessToken, accessExpiry > Date().addingTimeInterval(60) { return t }
        guard let refresh = Keychain.read(account: Keys.refreshAccount) else {
            isSignedIn = false
            throw ClassroomError.notSignedIn
        }
        guard isConfigured else { throw ClassroomError.notConfigured }
        do {
            let json = try await tokenRequest([
                "refresh_token": refresh,
                "client_id": clientID.trimmingCharacters(in: .whitespaces),
                "client_secret": clientSecret.trimmingCharacters(in: .whitespaces),
                "grant_type": "refresh_token"
            ])
            guard let access = json["access_token"] as? String else {
                throw ClassroomError.auth("no access token returned")
            }
            accessToken = access
            accessExpiry = Date().addingTimeInterval((json["expires_in"] as? Double) ?? 3000)
            return access
        } catch {
            // A revoked or expired refresh token needs a fresh sign-in.
            signOut()
            throw error
        }
    }

    // MARK: HTTP helpers

    private func apiRequest(_ url: URL, method: String = "GET", json: [String: Any]? = nil) async throws -> [String: Any] {
        var req = URLRequest(url: url)
        req.httpMethod = method
        let token = try await validAccessToken()
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        return try Self.parse(data, resp)
    }

    private static func parse(_ data: Data, _ resp: URLResponse) throws -> [String: Any] {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let http = resp as? HTTPURLResponse else { throw ClassroomError.http(0, "No response") }
        guard (200..<300).contains(http.statusCode) else {
            let msg = ((json["error"] as? [String: Any])?["message"] as? String) ?? "Request failed"
            throw ClassroomError.http(http.statusCode, msg)
        }
        return json
    }

    // MARK: Courses

    func courses() async throws -> [ClassroomCourse] {
        var result: [ClassroomCourse] = []
        var pageToken: String?
        repeat {
            var comps = URLComponents(string: "https://classroom.googleapis.com/v1/courses")!
            comps.queryItems = [
                .init(name: "teacherId", value: "me"),
                .init(name: "courseStates", value: "ACTIVE"),
                .init(name: "pageSize", value: "100")
            ]
            if let pageToken { comps.queryItems?.append(.init(name: "pageToken", value: pageToken)) }
            let json = try await apiRequest(comps.url!)
            for c in (json["courses"] as? [[String: Any]]) ?? [] {
                guard let id = c["id"] as? String, let name = c["name"] as? String else { continue }
                result.append(ClassroomCourse(id: id, name: name, section: c["section"] as? String))
            }
            pageToken = json["nextPageToken"] as? String
        } while pageToken != nil
        return result.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    // MARK: Topics

    /// Lists every topic defined in a course. Topics group CourseWork and
    /// CourseWorkMaterial posts; announcements cannot be topic-scoped.
    func topics(courseID: String) async throws -> [ClassroomTopic] {
        guard !courseID.isEmpty else { return [] }
        var result: [ClassroomTopic] = []
        var pageToken: String?
        repeat {
            var comps = URLComponents(string:
                "https://classroom.googleapis.com/v1/courses/\(courseID)/topics")!
            comps.queryItems = [.init(name: "pageSize", value: "100")]
            if let pageToken { comps.queryItems?.append(.init(name: "pageToken", value: pageToken)) }
            let json = try await apiRequest(comps.url!)
            for t in (json["topic"] as? [[String: Any]]) ?? [] {
                guard let id = t["topicId"] as? String,
                      let name = t["name"] as? String else { continue }
                result.append(ClassroomTopic(id: id, name: name))
            }
            pageToken = json["nextPageToken"] as? String
        } while pageToken != nil
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Create a new topic in a course and return its id. Classroom caps topic
    /// names at 100 characters; names over that are truncated.
    @discardableResult
    func createTopic(courseID: String, name: String) async throws -> ClassroomTopic {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        let url = URL(string: "https://classroom.googleapis.com/v1/courses/\(courseID)/topics")!
        let json = try await apiRequest(url, method: "POST", json: ["name": trimmed])
        guard let id = json["topicId"] as? String,
              let returnedName = json["name"] as? String else {
            throw ClassroomError.http(0, "Classroom did not return a topic")
        }
        return ClassroomTopic(id: id, name: returnedName)
    }

    // MARK: Drive upload

    /// Uploads a file to the teacher's Drive (resumable upload) and returns its file id.
    /// Unchanged files (same path, size and modified time) reuse their earlier upload.
    func uploadToDrive(_ fileURL: URL) async throws -> String {
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let cacheKey = "\(fileURL.path)|\(size)|\(Int(mtime))"
        var cache = UserDefaults.standard.dictionary(forKey: Keys.uploads) as? [String: String] ?? [:]
        if let id = cache[cacheKey] { return id }

        let mime = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        var start = URLRequest(url: URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&fields=id")!)
        start.httpMethod = "POST"
        let token = try await validAccessToken()
        start.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        start.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        start.setValue(mime, forHTTPHeaderField: "X-Upload-Content-Type")
        start.setValue(String(size), forHTTPHeaderField: "X-Upload-Content-Length")
        start.httpBody = try JSONSerialization.data(withJSONObject: ["name": fileURL.lastPathComponent])
        let (startData, startResp) = try await URLSession.shared.data(for: start)
        _ = try Self.parse(startData, startResp)
        guard let http = startResp as? HTTPURLResponse,
              let location = http.value(forHTTPHeaderField: "Location"),
              let sessionURL = URL(string: location) else {
            throw ClassroomError.http(0, "Drive did not return an upload address")
        }

        var put = URLRequest(url: sessionURL)
        put.httpMethod = "PUT"
        put.setValue(mime, forHTTPHeaderField: "Content-Type")
        let (data, resp) = try await URLSession.shared.upload(for: put, fromFile: fileURL)
        let json = try Self.parse(data, resp)
        guard let id = json["id"] as? String else {
            throw ClassroomError.http(0, "Drive did not return a file id")
        }
        cache[cacheKey] = id
        UserDefaults.standard.set(cache, forKey: Keys.uploads)
        return id
    }

    // MARK: Posting

    private static func isoString(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }

    private func materialsJSON(_ driveIDs: [String]) -> [[String: Any]] {
        driveIDs.map { ["driveFile": ["driveFile": ["id": $0], "shareMode": "VIEW"]] }
    }

    /// Creates an announcement or material in a course and returns the new post's id.
    /// `topicID` is applied only for `.material` posts — announcements aren't
    /// topic-scoped in Classroom.
    func post(kind: ClassroomKind,
              courseID: String,
              title: String,
              text: String,
              timing: ClassroomTiming,
              driveIDs: [String],
              topicID: String? = nil) async throws -> String {
        var body: [String: Any] = [:]
        switch timing {
        case .draft:
            body["state"] = "DRAFT"
        case .now:
            body["state"] = "PUBLISHED"
        case .scheduled(let date):
            body["state"] = "DRAFT"
            body["scheduledTime"] = Self.isoString(date)
        }
        if !driveIDs.isEmpty { body["materials"] = materialsJSON(driveIDs) }

        let path: String
        switch kind {
        case .announcement:
            body["text"] = title.isEmpty ? text : "\(title)\n\n\(text)"
            path = "announcements"
        case .material:
            body["title"] = title
            body["description"] = text
            if let topicID, !topicID.isEmpty {
                body["topicId"] = topicID
            }
            path = "courseWorkMaterials"
        }
        let url = URL(string: "https://classroom.googleapis.com/v1/courses/\(courseID)/\(path)")!
        let json = try await apiRequest(url, method: "POST", json: body)
        guard let id = json["id"] as? String else { throw ClassroomError.http(0, "Classroom did not return a post id") }
        return id
    }

    /// Updates the wording of a post this app created earlier. Classroom doesn't allow
    /// changing attachments afterwards, so this is text (and title, for materials) only.
    func updateText(kind: ClassroomKind, courseID: String, postID: String, title: String, text: String) async throws {
        let body: [String: Any]
        let mask: String
        let path: String
        switch kind {
        case .announcement:
            body = ["text": title.isEmpty ? text : "\(title)\n\n\(text)"]
            mask = "text"
            path = "announcements"
        case .material:
            body = ["title": title, "description": text]
            mask = "title,description"
            path = "courseWorkMaterials"
        }
        var comps = URLComponents(string: "https://classroom.googleapis.com/v1/courses/\(courseID)/\(path)/\(postID)")!
        comps.queryItems = [.init(name: "updateMask", value: mask)]
        _ = try await apiRequest(comps.url!, method: "PATCH", json: body)
    }

    // MARK: Utilities

    private static func randomString(_ length: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String((0..<length).map { _ in chars.randomElement()! })
    }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
