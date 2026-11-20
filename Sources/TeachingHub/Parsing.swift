import Foundation

enum FrontMatterParser {
    /// Parse a YAML-style front-matter block at the top of a file.
    /// Handles strings, dates, inline arrays `[a, b]`, and block-style `- item` lists.
    static func parse(_ contents: String) -> (frontMatter: [String: String], body: String) {
        let lines = contents.components(separatedBy: .newlines)
        guard let first = lines.first?.trimmingCharacters(in: .whitespaces),
              first == "---" else {
            return ([:], contents)
        }

        var fm: [String: String] = [:]
        var bodyStart = lines.count
        var currentKey: String?
        var currentList: [String] = []

        for i in 1..<lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" {
                if let k = currentKey, !currentList.isEmpty {
                    fm[k] = "[" + currentList.joined(separator: ", ") + "]"
                }
                bodyStart = i + 1
                break
            }
            if line.hasPrefix("- ") || line.hasPrefix("  -") || line.hasPrefix("\t-") {
                let v = trimmed.dropFirst(1).trimmingCharacters(in: .whitespaces)
                let cleaned = v.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                currentList.append(cleaned)
                continue
            }
            if let colonIdx = line.firstIndex(of: ":") {
                if let k = currentKey, !currentList.isEmpty {
                    fm[k] = "[" + currentList.joined(separator: ", ") + "]"
                    currentList = []
                }
                let key = String(line[..<colonIdx]).trimmingCharacters(in: .whitespaces)
                let raw = String(line[line.index(after: colonIdx)...])
                    .trimmingCharacters(in: .whitespaces)
                if raw.isEmpty {
                    currentKey = key
                } else if raw.hasPrefix("[") && raw.hasSuffix("]") {
                    let inner = String(raw.dropFirst().dropLast())
                    fm[key] = "[" + inner + "]"
                    currentKey = nil
                } else {
                    fm[key] = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    currentKey = nil
                }
            }
        }

        let body: String
        if bodyStart < lines.count {
            body = lines[bodyStart...].joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            body = ""
        }
        return (fm, body)
    }

    /// Try a list of common date formats. Returns nil + a flag for "had no time".
    static func parseDate(_ raw: String) -> (Date, Bool)? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let hasTime = trimmed.range(of: #"\d{1,2}:\d{2}"#, options: .regularExpression) != nil

        let formats = [
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd HH:mm",
            "yyyy-MM-dd",
            "yyyy/MM/dd",
            "MM/dd/yyyy",
            "dd/MM/yyyy"
        ]
        for fmt in formats {
            let f = DateFormatter()
            f.dateFormat = fmt
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone.current
            if let d = f.date(from: trimmed) {
                return (d, hasTime)
            }
        }
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: trimmed) {
            return (d, hasTime)
        }
        return nil
    }

    static func parseTags(_ value: String?) -> [String] {
        guard let raw = value else { return [] }
        return raw
            .replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) }
            .filter { !$0.isEmpty }
    }
}

enum RequirementsParser {
    /// Find a `## Requirements` (or Materials/Equipment/etc.) section in the body.
    /// Returns extracted bullet-list items + the body with the section removed.
    static func extract(from body: String) -> (items: [String], bodyWithout: String) {
        let lines = body.components(separatedBy: .newlines)
        let headingRegex = try! NSRegularExpression(pattern: #"^(#{1,6})\s+(.+?)\s*$"#)

        var sectionStart = -1
        var sectionLevel = 0
        for (i, line) in lines.enumerated() {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            if let m = headingRegex.firstMatch(in: line, range: range) {
                let levelRange = Range(m.range(at: 1), in: line)!
                let titleRange = Range(m.range(at: 2), in: line)!
                let title = String(line[titleRange]).lowercased().trimmingCharacters(in: .whitespaces)
                if ["requirements", "requires", "needs", "materials", "equipment"].contains(title) {
                    sectionStart = i
                    sectionLevel = String(line[levelRange]).count
                    break
                }
            }
        }
        guard sectionStart != -1 else { return ([], body) }

        var sectionEnd = lines.count
        for i in (sectionStart + 1)..<lines.count {
            let line = lines[i]
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            if let m = headingRegex.firstMatch(in: line, range: range) {
                let levelRange = Range(m.range(at: 1), in: line)!
                if String(line[levelRange]).count <= sectionLevel {
                    sectionEnd = i
                    break
                }
            }
        }

        let bulletRegex = try! NSRegularExpression(pattern: #"^\s*(?:[-*+]|\d+\.)\s+(.+?)\s*$"#)
        let checkboxRegex = try! NSRegularExpression(pattern: #"^\[\s*[ xX]?\s*\]\s*"#)
        var items: [String] = []
        for i in (sectionStart + 1)..<sectionEnd {
            let line = lines[i]
            let lr = NSRange(line.startIndex..<line.endIndex, in: line)
            if let m = bulletRegex.firstMatch(in: line, range: lr) {
                let r = Range(m.range(at: 1), in: line)!
                var text = String(line[r])
                let tr = NSRange(text.startIndex..<text.endIndex, in: text)
                text = checkboxRegex.stringByReplacingMatches(in: text, range: tr, withTemplate: "")
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { items.append(trimmed) }
            }
        }

        let before = lines[0..<sectionStart].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let after = sectionEnd < lines.count
            ? lines[sectionEnd...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        let combined = [before, after].filter { !$0.isEmpty }.joined(separator: "\n\n")
        return (items, combined)
    }
}

enum MarkdownComposer {
    /// Compose a complete .md file from structured fields + a Requirements section.
    static func compose(
        title: String,
        date: Date,
        includeTime: Bool,
        endDate: Date?,
        tags: [String],
        body: String,
        requirements: [String],
        extraFields: [(String, String)]
    ) -> String {
        var lines: [String] = ["---"]
        lines.append("title: \(escape(title))")
        lines.append("date: \(formatDate(date, includeTime: includeTime))")
        if let endDate, includeTime {
            lines.append("end: \(formatDate(endDate, includeTime: true))")
        }
        if !tags.isEmpty {
            lines.append("tags: [\(tags.map(escape).joined(separator: ", "))]")
        }
        for (k, v) in extraFields where !v.isEmpty {
            lines.append("\(k): \(escape(v))")
        }
        lines.append("---")
        lines.append("")
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            lines.append(trimmed)
        }
        if !requirements.isEmpty {
            if !trimmed.isEmpty { lines.append("") }
            lines.append("## Requirements")
            lines.append("")
            for r in requirements { lines.append("- \(r)") }
        }
        return lines.joined(separator: "\n")
    }

    private static func escape(_ s: String) -> String {
        // YAML-quote if special chars present
        let needsQuoting = s.first.map { "\"'#&*!|>%@`".contains($0) } ?? false
            || s.contains(":")
            || s != s.trimmingCharacters(in: .whitespaces)
        if needsQuoting {
            let escaped = s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }
        return s
    }

    private static func formatDate(_ date: Date, includeTime: Bool) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = includeTime ? "yyyy-MM-dd HH:mm" : "yyyy-MM-dd"
        return f.string(from: date)
    }
}
