import AppKit
import Foundation
import CoreGraphics

/// PDF export in five scopes: Lesson, Day, Week (full), Topic, and
/// Week Overview (a compact one-pager with timings + brief details).
///
/// All rendering is direct CoreGraphics — a CGPDFContext with
/// NSAttributedString.draw(with:). No SwiftUI hosting view, no
/// NSPrintOperation. Automatic pagination on a per-block basis.
enum PDFExport {

    // MARK: - Entry points

    static func exportLesson(_ entry: Entry) {
        guard let url = pickSaveLocation(suggestedName: "\(filenameSafe(entry.title)).pdf") else { return }
        render(to: url) { pdf in
            drawDocumentTitle(
                pdf: pdf,
                eyebrow: entry.classDisplay.isEmpty ? "LESSON" : entry.classDisplay.uppercased(),
                title: entry.title,
                subtitle: dateAndTimeSubtitle(for: entry)
            )
            drawLessonBody(pdf: pdf, entry: entry, compact: false, showClass: false, showDateHeader: false)
        }
    }

    static func exportDay(_ date: Date, entries allEntries: [Entry]) {
        let entries = allEntries.filter { Calendar.current.isDate($0.date, inSameDayAs: date) }
                                .sorted { $0.date < $1.date }
        let fm = DateFormatter(); fm.dateFormat = "yyyy-MM-dd"
        guard let url = pickSaveLocation(suggestedName: "Day-\(fm.string(from: date)).pdf") else { return }
        render(to: url) { pdf in
            drawDocumentTitle(
                pdf: pdf,
                eyebrow: "DAY",
                title: Fmt.longDay.string(from: date),
                subtitle: "\(entries.count) lesson\(entries.count == 1 ? "" : "s")"
            )
            if entries.isEmpty {
                pdf.addItalic("No lessons on this day.")
            } else {
                for (i, e) in entries.enumerated() {
                    if i > 0 { pdf.addSpacer(12) }
                    drawLessonBody(pdf: pdf, entry: e, compact: false, showClass: true, showDateHeader: false)
                }
            }
        }
    }

    static func exportWeek(anchoredAt date: Date, entries allEntries: [Entry]) {
        var cal = Calendar(identifier: .gregorian); cal.firstWeekday = 2
        let start = cal.dateInterval(of: .weekOfYear, for: date)?.start ?? date
        let end = cal.date(byAdding: .day, value: 7, to: start) ?? date
        let weekEntries = allEntries.filter { $0.date >= start && $0.date < end }.sorted { $0.date < $1.date }
        let fm = DateFormatter(); fm.dateFormat = "yyyy-MM-dd"
        guard let url = pickSaveLocation(suggestedName: "Week-\(fm.string(from: start)).pdf") else { return }
        render(to: url) { pdf in
            let endDay = cal.date(byAdding: .day, value: 4, to: start) ?? start
            drawDocumentTitle(
                pdf: pdf,
                eyebrow: "WEEK",
                title: "Week of \(Fmt.shortDay.string(from: start))",
                subtitle: "\(Fmt.longDay.string(from: start)) – \(Fmt.longDay.string(from: endDay))  ·  \(weekEntries.count) lessons"
            )
            let grouped = Dictionary(grouping: weekEntries) { cal.startOfDay(for: $0.date) }
            for offset in 0..<5 {
                let d = cal.date(byAdding: .day, value: offset, to: start)!
                let dayStart = cal.startOfDay(for: d)
                let todays = (grouped[dayStart] ?? []).sorted { $0.date < $1.date }
                pdf.addDayHeader(Fmt.longDay.string(from: d))
                if todays.isEmpty {
                    pdf.addItalic("No lessons.")
                } else {
                    for e in todays { drawLessonBody(pdf: pdf, entry: e, compact: true, showClass: true, showDateHeader: false) }
                }
                pdf.addSpacer(10)
            }
        }
    }

    /// Compact single-view "week at a glance": for each day, a time-column
    /// table of lessons with brief details — class, title, first line or two
    /// of the body. No full markdown bodies, no requirements section, no
    /// resource lists.
    static func exportWeekOverview(anchoredAt date: Date, entries allEntries: [Entry]) {
        var cal = Calendar(identifier: .gregorian); cal.firstWeekday = 2
        let start = cal.dateInterval(of: .weekOfYear, for: date)?.start ?? date
        let end = cal.date(byAdding: .day, value: 7, to: start) ?? date
        let weekEntries = allEntries.filter { $0.date >= start && $0.date < end }.sorted { $0.date < $1.date }
        let fm = DateFormatter(); fm.dateFormat = "yyyy-MM-dd"
        guard let url = pickSaveLocation(suggestedName: "Week-overview-\(fm.string(from: start)).pdf") else { return }
        render(to: url) { pdf in
            let endDay = cal.date(byAdding: .day, value: 4, to: start) ?? start
            drawDocumentTitle(
                pdf: pdf,
                eyebrow: "WEEK OVERVIEW",
                title: "Week of \(Fmt.shortDay.string(from: start))",
                subtitle: "\(Fmt.longDay.string(from: start)) – \(Fmt.longDay.string(from: endDay))  ·  \(weekEntries.count) lessons"
            )
            let grouped = Dictionary(grouping: weekEntries) { cal.startOfDay(for: $0.date) }
            for offset in 0..<5 {
                let d = cal.date(byAdding: .day, value: offset, to: start)!
                let dayStart = cal.startOfDay(for: d)
                let todays = (grouped[dayStart] ?? []).sorted { $0.date < $1.date }
                pdf.addDayHeader(Fmt.longDay.string(from: d))
                if todays.isEmpty {
                    pdf.addItalic("—")
                    pdf.addSpacer(6)
                    continue
                }
                for e in todays { pdf.addOverviewRow(entry: e) }
                pdf.addSpacer(8)
            }
        }
    }

    /// Weekly technician sheet — for every lesson in Mon-Fri, scale the
    /// "Requirements" list by the class's recorded student count. Lessons
    /// with no requirements are skipped.
    static func exportTechnician(anchoredAt date: Date, entries allEntries: [Entry], classes: [ClassConfig]) {
        var cal = Calendar(identifier: .gregorian); cal.firstWeekday = 2
        let start = cal.dateInterval(of: .weekOfYear, for: date)?.start ?? date
        let end = cal.date(byAdding: .day, value: 7, to: start) ?? date
        let weekEntries = allEntries.filter { $0.date >= start && $0.date < end }.sorted { $0.date < $1.date }
        let classBySlug: [String: ClassConfig] = Dictionary(uniqueKeysWithValues: classes.map { ($0.slug, $0) })
        let fm = DateFormatter(); fm.dateFormat = "yyyy-MM-dd"
        guard let url = pickSaveLocation(suggestedName: "Technician-sheet-\(fm.string(from: start)).pdf") else { return }
        render(to: url) { pdf in
            let endDay = cal.date(byAdding: .day, value: 4, to: start) ?? start
            drawDocumentTitle(
                pdf: pdf,
                eyebrow: "TECHNICIAN SHEET",
                title: "Week of \(Fmt.shortDay.string(from: start))",
                subtitle: "\(Fmt.longDay.string(from: start)) – \(Fmt.longDay.string(from: endDay))  ·  materials by class, scaled to roll"
            )
            let grouped = Dictionary(grouping: weekEntries) { cal.startOfDay(for: $0.date) }
            var totalLessonsWithMaterials = 0
            for offset in 0..<5 {
                let d = cal.date(byAdding: .day, value: offset, to: start)!
                let dayStart = cal.startOfDay(for: d)
                let todays = (grouped[dayStart] ?? []).sorted { $0.date < $1.date }

                // Filter to only lessons that have any material requirements
                let withMats = todays.filter { !Self.rawRequirements(for: $0).isEmpty }
                pdf.addDayHeader(Fmt.longDay.string(from: d))
                if withMats.isEmpty {
                    pdf.addItalic("No materials needed.")
                    pdf.addSpacer(4)
                    continue
                }
                for e in withMats {
                    let cfg = e.classSlug.flatMap { classBySlug[$0] }
                    pdf.addTechnicianLessonBlock(entry: e, classConfig: cfg)
                    totalLessonsWithMaterials += 1
                }
            }
            if totalLessonsWithMaterials == 0 {
                pdf.addSpacer(10)
                pdf.addItalic("No lessons this week have a `## Requirements` section — nothing needed from the tech team.")
            }
        }
    }

    static func exportTopic(title: String, entries: [Entry]) {
        let sorted = entries.sorted { $0.date < $1.date }
        guard let url = pickSaveLocation(suggestedName: "\(filenameSafe(title)).pdf") else { return }
        render(to: url) { pdf in
            var sub = "\(sorted.count) lesson\(sorted.count == 1 ? "" : "s")"
            if let first = sorted.first, let last = sorted.last {
                sub += "  ·  \(Fmt.shortDay.string(from: first.date)) – \(Fmt.shortDay.string(from: last.date))"
            }
            drawDocumentTitle(pdf: pdf, eyebrow: "TOPIC", title: title, subtitle: sub)
            for (i, e) in sorted.enumerated() {
                if i > 0 { pdf.addSpacer(12) }
                drawLessonBody(pdf: pdf, entry: e, compact: false, showClass: true, showDateHeader: true)
            }
        }
    }

    // MARK: - Save panel

    private static func pickSaveLocation(suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = "Export as PDF"
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [.pdf]
        return panel.runModal() == .OK ? panel.url : nil
    }

    private static func filenameSafe(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let scalars = s.unicodeScalars.map { bad.contains($0) ? "-" : String($0) }
        return scalars.joined().trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Render driver

    private static func render(to url: URL, _ build: (PDFBuilder) -> Void) {
        let pdf = PDFBuilder(url: url)
        pdf.beginDocument()
        build(pdf)
        pdf.endDocument()
    }

    // MARK: - Shared content blocks

    private static func dateAndTimeSubtitle(for entry: Entry) -> String {
        var line = Fmt.longDay.string(from: entry.date)
        if !entry.timeString.isEmpty { line += "  ·  \(entry.timeString)" }
        return line
    }

    private static func drawDocumentTitle(pdf: PDFBuilder, eyebrow: String, title: String, subtitle: String) {
        pdf.addEyebrow(eyebrow)
        pdf.addHeading(title)
        if !subtitle.isEmpty { pdf.addSubtitleLine(subtitle) }
        pdf.addAccentBar()
        pdf.addSpacer(8)
    }

    private static func drawLessonBody(pdf: PDFBuilder, entry: Entry, compact: Bool, showClass: Bool, showDateHeader: Bool) {
        pdf.beginLessonCard()
        if showDateHeader {
            pdf.addLessonDateHeader(Fmt.longDay.string(from: entry.date))
        }
        pdf.addLessonTitleRow(
            time: entry.timeString,
            title: entry.title,
            className: showClass ? entry.classDisplay : ""
        )

        let body = (compact ? firstParagraphs(entry.body, max: 600) : entry.bodyFull)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty {
            pdf.addMarkdown(body, compact: compact)
        }

        if !entry.requirements.isEmpty && !entry.bodyFull.contains("## Requirements") {
            pdf.addLabel("Requirements")
            pdf.addBullets(entry.requirements)
        }

        if !entry.resources.isEmpty {
            pdf.addLabel("Resources")
            for r in entry.resources {
                pdf.addResourceLine(name: r.name, path: resolvedPath(for: r))
            }
        }

        pdf.addSourceLine("Source: \(entry.url.path)")
        pdf.endLessonCard()
    }

    // MARK: - Technician sheet helpers

    /// Pull material-requirement lines from a lesson's body.
    /// Looks first at `entry.requirements` (parsed explicitly from the
    /// front matter), then at a `## Requirements` section in the body.
    static func rawRequirements(for entry: Entry) -> [String] {
        var items: [String] = []
        items.append(contentsOf: entry.requirements)
        // Also pick up anything under a "## Requirements" heading in the body
        if let range = entry.bodyFull.range(of: #"(?m)^##\s+Requirements\s*$"#, options: .regularExpression) {
            let after = entry.bodyFull[range.upperBound...]
            for raw in after.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = String(raw).trimmingCharacters(in: .whitespaces)
                if line.isEmpty { continue }
                if line.hasPrefix("##") { break }  // next heading
                if line.hasPrefix("-") || line.hasPrefix("*") {
                    var body = line
                    body.removeFirst()
                    body = body.trimmingCharacters(in: .whitespaces)
                    if body.contains("add materials") { continue }  // skip placeholder
                    body = body.replacingOccurrences(of: "**", with: "")
                    if !body.isEmpty, !items.contains(body) { items.append(body) }
                }
            }
        }
        return items
    }

    /// Resolution of a single requirement line against a class roster.
    struct ScaledRequirement {
        /// Quantity to prepare; nil when we couldn't determine one.
        let qty: Int?
        /// Human-readable item description (with scaling qualifier removed).
        let item: String
        /// Short note like "per student" or "per pair of 2".
        let note: String?
        /// Original line as the teacher wrote it, for fallback display.
        let original: String
    }

    /// Parse a requirement line and scale it by class size.
    /// Recognised forms (case-insensitive, flexible whitespace):
    ///   "30 test tubes"                        → 30, "test tubes", nil
    ///   "test tubes (per student)"             → N,  "test tubes", "per student"
    ///   "2 beakers (per pair)"                 → 2 * ceil(N/2), "beakers", "per pair"
    ///   "Bunsen burner (per group of 4)"       → ceil(N/4), "Bunsen burner", "per group of 4"
    ///   "1 Bunsen burner (per group of 3)"     → 1 * ceil(N/3)
    ///   "data projector (shared / per class)"  → 1, item, "shared"
    ///   "leaves"                               → nil, "leaves", nil  (no scaling info — list as-is)
    static func scaleRequirement(_ raw: String, students: Int?) -> ScaledRequirement {
        var text = raw.trimmingCharacters(in: .whitespaces)

        enum Scaling { case absolute, perStudent, perGroup(Int), shared, unknown }
        var scaling: Scaling = .unknown
        var scalingNote: String? = nil

        // Extract trailing parenthetical qualifier(s): "(per student)", "(x per pair)", etc.
        let qualifierPattern = #"\s*[\(\[]([^)\]]+)[\)\]]\s*$"#
        if let qmatch = text.range(of: qualifierPattern, options: .regularExpression) {
            let inner = String(text[qmatch])
                .trimmingCharacters(in: CharacterSet(charactersIn: " ()[]"))
                .lowercased()
            if inner.contains("per student") || inner == "each" {
                scaling = .perStudent; scalingNote = "per student"
            } else if inner.contains("per pair") || inner.contains("per two") {
                scaling = .perGroup(2); scalingNote = "per pair"
            } else if inner.contains("shared") || inner.contains("per class") || inner.contains("whole class") {
                scaling = .shared; scalingNote = "shared"
            } else if let gsize = parseGroupSize(inner) {
                scaling = .perGroup(gsize); scalingNote = "per group of \(gsize)"
            }
            if case .unknown = scaling {
                // Leave scaling as unknown — this is a free-text annotation we don't understand.
            } else {
                text = String(text[text.startIndex..<qmatch.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
        }

        // Extract leading quantity "30 test tubes"
        var leadingQty: Int? = nil
        if let m = text.range(of: #"^(\d+)\s*(?:×|x|\*)?\s+"#, options: .regularExpression) {
            let numStr = String(text[m]).trimmingCharacters(in: CharacterSet(charactersIn: " ×x*"))
            leadingQty = Int(numStr)
            text = String(text[m.upperBound...]).trimmingCharacters(in: .whitespaces)
        }

        // Compute total quantity
        var total: Int? = nil
        let n = students ?? 0
        switch scaling {
        case .absolute:
            total = leadingQty
        case .perStudent:
            total = (leadingQty ?? 1) * max(n, 0)
        case .perGroup(let size):
            if n > 0 {
                let groups = Int(ceil(Double(n) / Double(size)))
                total = (leadingQty ?? 1) * groups
            } else {
                total = nil
            }
        case .shared:
            total = leadingQty ?? 1
        case .unknown:
            // No scaling info at all — if there's an absolute quantity, use it;
            // otherwise leave unknown so the tech sees the original text.
            total = leadingQty
        }

        // Without a roster we can only trust absolute/shared quantities
        if students == nil {
            switch scaling {
            case .perStudent, .perGroup: total = nil
            case .absolute, .shared, .unknown: break
            }
        }

        return ScaledRequirement(qty: total, item: text, note: scalingNote, original: raw)
    }

    private static func parseGroupSize(_ qualifier: String) -> Int? {
        // "per group of 3", "group of 4"
        if let m = qualifier.range(of: #"per group of (\d+)"#, options: .regularExpression) {
            let piece = String(qualifier[m])
            return Int(piece.split(separator: " ").last ?? "")
        }
        if let m = qualifier.range(of: #"group of (\d+)"#, options: .regularExpression) {
            let piece = String(qualifier[m])
            return Int(piece.split(separator: " ").last ?? "")
        }
        return nil
    }

    private static func resolvedPath(for r: Resource) -> String {
        let fm = FileManager.default
        if let dest = try? fm.destinationOfSymbolicLink(atPath: r.url.path), !dest.isEmpty {
            if dest.hasPrefix("/") { return dest }
            let base = r.url.deletingLastPathComponent().path
            return (base as NSString).appendingPathComponent(dest)
        }
        return r.url.path
    }

    private static func firstParagraphs(_ s: String, max: Int) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= max { return trimmed }
        return String(trimmed.prefix(max)) + "…"
    }
}

// MARK: - Formatters

private enum Fmt {
    static let longDay: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEEE d MMMM yyyy"; return f
    }()
    static let shortDay: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE d MMM"; return f
    }()
    static let time: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()
    static let generated: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "d MMM yyyy, HH:mm"; return f
    }()
}

private extension Entry {
    var timeString: String {
        guard hasTime else { return "" }
        if let end = endDate {
            return "\(Fmt.time.string(from: date)) – \(Fmt.time.string(from: end))"
        }
        return Fmt.time.string(from: date)
    }
    var classDisplay: String {
        guard let s = classSlug else { return "" }
        return s.replacingOccurrences(of: "-", with: " ").capitalized
    }
    /// Pull the first body line that isn't a heading, isn't the
    /// title-echo, and isn't bare punctuation. Used in Week Overview.
    var bodyTeaser: String {
        for raw in body.split(separator: "\n") {
            var line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") { continue }
            while line.hasPrefix("-") || line.hasPrefix("*") || line.hasPrefix(">") {
                line.removeFirst()
                line = line.trimmingCharacters(in: .whitespaces)
            }
            line = line.replacingOccurrences(of: "**", with: "")
            line = line.replacingOccurrences(of: "__", with: "")
            // Skip the title echo
            let stripped = line.replacingOccurrences(of: #"\s*\([^)]*\)\s*$"#,
                                                     with: "", options: .regularExpression).lowercased()
            if stripped == title.lowercased() { continue }
            return String(line.prefix(200))
        }
        return ""
    }
}

// MARK: - PDFBuilder — direct CoreGraphics renderer

private final class PDFBuilder {
    private let url: URL
    private var ctx: CGContext?
    private let pageSize = CGSize(width: 595, height: 842)   // A4 @ 72 dpi
    private let margin: CGFloat = 48
    private var y: CGFloat = 0
    private var pageNumber: Int = 0

    // Accent colour — matches app purple
    private let accent = NSColor(calibratedRed: 0.42, green: 0.36, blue: 0.82, alpha: 1)
    private let softBorder = NSColor(white: 0.85, alpha: 1)
    private let softLabel = NSColor(white: 0.35, alpha: 1)
    private let cardTint = NSColor(white: 0.97, alpha: 1)
    private let timeTint = NSColor(calibratedRed: 0.95, green: 0.93, blue: 1.0, alpha: 1)

    // Running card state
    private var cardStartY: CGFloat? = nil

    init(url: URL) { self.url = url }

    var contentWidth: CGFloat { pageSize.width - margin * 2 }

    func beginDocument() {
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else { return }
        self.ctx = ctx
        newPage()
    }

    func endDocument() {
        guard let ctx = ctx else { return }
        drawFooter()
        ctx.endPDFPage()
        ctx.closePDF()
        self.ctx = nil
    }

    func newPage() {
        guard let ctx = ctx else { return }
        if pageNumber > 0 {
            drawFooter()
            ctx.endPDFPage()
        }
        pageNumber += 1
        ctx.beginPDFPage(nil)
        ctx.saveGState()
        ctx.translateBy(x: 0, y: pageSize.height)
        ctx.scaleBy(x: 1, y: -1)
        y = margin
    }

    // MARK: Document title

    func addEyebrow(_ text: String) {
        let attr = Self.attrString(text, font: .systemFont(ofSize: 9, weight: .bold), color: accent, kern: 2)
        draw(attr); y += 1
    }

    func addHeading(_ text: String) {
        let attr = Self.attrString(text, font: .systemFont(ofSize: 26, weight: .bold), color: .black)
        draw(attr); y += 2
    }

    func addSubtitleLine(_ text: String) {
        let attr = Self.attrString(text, font: .systemFont(ofSize: 11), color: softLabel)
        draw(attr)
    }

    func addAccentBar() {
        guard let ctx = ctx else { return }
        y += 10
        ctx.saveGState()
        ctx.setFillColor(accent.cgColor)
        // Context is flipped (top-left origin, y grows down) — use plain y
        ctx.fill(CGRect(x: margin, y: y, width: 48, height: 3))
        ctx.restoreGState()
        y += 6
    }

    // MARK: Day header

    func addDayHeader(_ text: String) {
        guard let ctx = ctx else { return }
        y += 8
        let bandHeight: CGFloat = 24
        if y + bandHeight + 4 > pageSize.height - margin { newPage() }
        // Clean tinted banner — flipped context, top-left origin
        ctx.saveGState()
        ctx.setFillColor(accent.withAlphaComponent(0.12).cgColor)
        let rect = CGRect(x: margin, y: y, width: contentWidth, height: bandHeight)
        let path = CGPath(roundedRect: rect, cornerWidth: 3, cornerHeight: 3, transform: nil)
        ctx.addPath(path); ctx.fillPath()
        ctx.restoreGState()
        // Day text, vertically centred in the band
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        let attr = Self.attrString(text, font: .systemFont(ofSize: 12, weight: .semibold), color: accent)
        let textSize = attr.boundingRect(with: CGSize(width: contentWidth - 20, height: bandHeight),
                                         options: [.usesLineFragmentOrigin])
        let textY = y + (bandHeight - ceil(textSize.height)) / 2
        attr.draw(at: CGPoint(x: margin + 12, y: textY))
        NSGraphicsContext.restoreGraphicsState()
        y += bandHeight + 4
    }

    // MARK: Lesson card

    func beginLessonCard() {
        cardStartY = y
        y += 10   // top padding inside the card
    }

    func endLessonCard() {
        guard let ctx = ctx, let startY = cardStartY else { return }
        y += 10   // bottom padding
        // Flipped context: rect top is at startY, extends down to y
        let rect = CGRect(x: margin,
                          y: startY,
                          width: contentWidth,
                          height: y - startY)
        ctx.saveGState()
        ctx.setStrokeColor(softBorder.cgColor)
        ctx.setLineWidth(0.5)
        let path = CGPath(roundedRect: rect, cornerWidth: 5, cornerHeight: 5, transform: nil)
        ctx.addPath(path)
        ctx.strokePath()
        ctx.restoreGState()
        cardStartY = nil
        y += 8
    }

    func addLessonDateHeader(_ text: String) {
        let attr = Self.attrString(text, font: .systemFont(ofSize: 10, weight: .medium), color: accent, kern: 0.3)
        drawPadded(attr); y += 3
    }

    /// Time badge + title + class on one aligned row.
    func addLessonTitleRow(time: String, title: String, className: String) {
        guard let ctx = ctx else { return }

        let timeFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        let titleFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
        let classFont = NSFont.systemFont(ofSize: 9, weight: .medium)

        let hasTime = !time.isEmpty
        let timeWidth: CGFloat = hasTime ? 92 : 0

        // Time badge
        if hasTime {
            let timeAttr = Self.attrString(time, font: timeFont, color: .black)
            let timeSize = timeAttr.boundingRect(with: CGSize(width: timeWidth, height: 30),
                                                 options: [.usesLineFragmentOrigin])
            let badgeHeight: CGFloat = 20
            let badgeRect = CGRect(x: margin + 12,
                                   y: y - 2,
                                   width: timeWidth - 10,
                                   height: badgeHeight)
            ctx.saveGState()
            ctx.setFillColor(timeTint.cgColor)
            let path = CGPath(roundedRect: badgeRect, cornerWidth: 3, cornerHeight: 3, transform: nil)
            ctx.addPath(path); ctx.fillPath()
            ctx.restoreGState()
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            let textY = y - 2 + (badgeHeight - ceil(timeSize.height)) / 2
            timeAttr.draw(at: CGPoint(x: margin + 16, y: textY))
            NSGraphicsContext.restoreGraphicsState()
        }

        let titleX = margin + 12 + timeWidth + (hasTime ? 6 : 0)
        let titleWidth = contentWidth - (12 + timeWidth + (hasTime ? 6 : 0)) - 12
        let titleAttr = Self.attrString(title, font: titleFont, color: .black)
        let titleSize = titleAttr.boundingRect(with: CGSize(width: titleWidth, height: 200),
                                               options: [.usesLineFragmentOrigin, .usesFontLeading])
        let titleHeight = ceil(titleSize.height)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        titleAttr.draw(with: CGRect(x: titleX, y: y, width: titleWidth, height: titleHeight),
                       options: [.usesLineFragmentOrigin, .usesFontLeading])
        if !className.isEmpty {
            let classAttr = Self.attrString(className.uppercased(), font: classFont, color: softLabel, kern: 0.5)
            let classSize = classAttr.boundingRect(with: CGSize(width: titleWidth, height: 20),
                                                   options: [.usesLineFragmentOrigin])
            let classY = y + titleHeight + 2
            classAttr.draw(at: CGPoint(x: titleX, y: classY))
            y = classY + ceil(classSize.height) + 2
        } else {
            y += titleHeight + 2
        }
        NSGraphicsContext.restoreGraphicsState()
        y += 4
    }

    // MARK: - Week Overview compact row

    /// A technician's view of one lesson: class + time + title line, roll
    /// count badge, then a two-column list of required items (quantity + item).
    func addTechnicianLessonBlock(entry: Entry, classConfig: ClassConfig?) {
        let items = PDFExport.rawRequirements(for: entry)
        let roll = classConfig?.students
        beginLessonCard()
        // Top row: time badge + class + title
        addLessonTitleRow(
            time: entry.timeString,
            title: entry.title,
            className: entry.classDisplay
        )
        // Roll badge
        if let roll = roll {
            addLabel("Class size: \(roll) students\(classConfig?.periods.first(where: { $0.day.rawValue == Calendar.current.component(.weekday, from: entry.date) })?.room.map { "   ·   Room: \($0)" } ?? "")")
        } else {
            addLabel("Class size: unknown — set `students: N` in classes/\(entry.classSlug ?? "<slug>").conf to scale materials")
        }

        // Materials table
        addLabel("Materials")
        guard let ctx = ctx else { endLessonCard(); return }
        let qtyFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        let itemFont = NSFont.systemFont(ofSize: 11)
        let noteFont = NSFont.systemFont(ofSize: 9)
        let qtyCol: CGFloat = 60
        let gutter: CGFloat = 10

        for raw in items {
            let scaled = PDFExport.scaleRequirement(raw, students: roll)
            let qtyText: String = scaled.qty.map { "\($0) ×" } ?? "—"
            if y + 22 > pageSize.height - margin { newPage(); cardStartY = y - 10 }

            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)

            // Qty column — right-aligned in the column
            let qtyAttr = Self.attrString(qtyText, font: qtyFont, color: scaled.qty == nil ? softLabel : .black)
            let qtySize = qtyAttr.boundingRect(with: CGSize(width: qtyCol, height: 20),
                                               options: [.usesLineFragmentOrigin])
            let qtyX = margin + 16 + qtyCol - ceil(qtySize.width) - 4
            qtyAttr.draw(at: CGPoint(x: qtyX, y: y))

            // Item + optional note
            let itemX = margin + 16 + qtyCol + gutter
            let itemW = contentWidth - 32 - qtyCol - gutter
            let itemAttr = Self.attrString(scaled.item, font: itemFont, color: .black)
            let itemSize = itemAttr.boundingRect(with: CGSize(width: itemW, height: 40),
                                                 options: [.usesLineFragmentOrigin])
            itemAttr.draw(with: CGRect(x: itemX, y: y, width: itemW, height: ceil(itemSize.height)),
                          options: [.usesLineFragmentOrigin])
            var used = ceil(itemSize.height)
            if let note = scaled.note {
                let noteAttr = Self.attrString(note, font: noteFont, color: softLabel)
                let noteSize = noteAttr.boundingRect(with: CGSize(width: itemW, height: 20),
                                                     options: [.usesLineFragmentOrigin])
                noteAttr.draw(at: CGPoint(x: itemX, y: y + used + 1))
                used += ceil(noteSize.height) + 1
            }
            NSGraphicsContext.restoreGraphicsState()
            y += max(used, 14) + 4
        }
        endLessonCard()
    }

    /// A single lesson row for the Week Overview — one line: time | class pill |
    /// title, with an optional second-line teaser pulled from the body.
    /// Long class names (e.g. "Year 13 Physics") are abbreviated to prevent
    /// the class text overflowing its column into the title.
    func addOverviewRow(entry: Entry) {
        guard let ctx = ctx else { return }
        let rowMinHeight: CGFloat = 32
        if y + rowMinHeight > pageSize.height - margin { newPage() }

        let timeFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        let classFont = NSFont.systemFont(ofSize: 8.5, weight: .semibold)
        let titleFont = NSFont.systemFont(ofSize: 11, weight: .medium)
        let teaserFont = NSFont.systemFont(ofSize: 9)

        let timeStr = entry.timeString.isEmpty ? "all day" : entry.timeString
        let classStr = Self.compactClass(entry.classDisplay)
        let title = entry.title
        let teaser = entry.bodyTeaser

        let timeWidth: CGFloat  = 86
        let classWidth: CGFloat = 78      // widened + we abbreviate in compactClass()
        let gutter: CGFloat     = 10
        let textX = margin + timeWidth + classWidth + gutter
        let textWidth = contentWidth - timeWidth - classWidth - gutter

        // Row content
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)

        // Time column
        Self.attrString(timeStr, font: timeFont, color: .black)
            .draw(at: CGPoint(x: margin, y: y + 1))

        // Class pill — rounded tinted background with class text inside.
        // Draw via a save/restore pair around the fill, keeping the flipped
        // graphics context intact for the text pass.
        if !classStr.isEmpty {
            let pillText = Self.attrString(classStr, font: classFont, color: accent, kern: 0.3)
            let textSize = pillText.boundingRect(
                with: CGSize(width: classWidth, height: 20),
                options: [.usesLineFragmentOrigin]
            )
            let pillH: CGFloat = 16
            let pillW: CGFloat = min(classWidth - 6, ceil(textSize.width) + 14)
            ctx.saveGState()
            ctx.setFillColor(accent.withAlphaComponent(0.12).cgColor)
            let pillRect = CGRect(x: margin + timeWidth, y: y - 2, width: pillW, height: pillH)
            ctx.addPath(CGPath(roundedRect: pillRect, cornerWidth: pillH/2, cornerHeight: pillH/2, transform: nil))
            ctx.fillPath()
            ctx.restoreGState()
            // Centre text in pill (NSGraphicsContext is still flipped from earlier save)
            let textY = y - 2 + (pillH - ceil(textSize.height)) / 2
            pillText.draw(at: CGPoint(x: margin + timeWidth + 7, y: textY))
        }

        // Title (right column)
        let titleAttr = Self.attrString(title, font: titleFont, color: .black)
        let titleSize = titleAttr.boundingRect(with: CGSize(width: textWidth, height: 40),
                                               options: [.usesLineFragmentOrigin])
        let titleH = ceil(titleSize.height)
        titleAttr.draw(with: CGRect(x: textX, y: y, width: textWidth, height: titleH),
                       options: [.usesLineFragmentOrigin])

        var usedHeight = titleH
        if !teaser.isEmpty {
            let teaserAttr = Self.attrString(teaser, font: teaserFont, color: softLabel)
            let teaserSize = teaserAttr.boundingRect(with: CGSize(width: textWidth, height: 40),
                                                     options: [.usesLineFragmentOrigin])
            let teaserH = min(ceil(teaserSize.height), 26)
            teaserAttr.draw(with: CGRect(x: textX, y: y + titleH + 1, width: textWidth, height: teaserH),
                            options: [.usesLineFragmentOrigin])
            usedHeight = titleH + 1 + teaserH
        }
        NSGraphicsContext.restoreGraphicsState()

        y += max(usedHeight, 16) + 8
        // Hairline divider under row (flipped coords — plain y)
        ctx.saveGState()
        ctx.setStrokeColor(softBorder.cgColor)
        ctx.setLineWidth(0.3)
        ctx.move(to: CGPoint(x: margin, y: y))
        ctx.addLine(to: CGPoint(x: margin + contentWidth, y: y))
        ctx.strokePath()
        ctx.restoreGState()
        y += 4
    }

    /// Shorten common class names for the compact overview column:
    ///   "Year 10"          -> "YEAR 10"
    ///   "Year 11"          -> "YEAR 11"
    ///   "Year 13 Physics"  -> "Y13 PHYSICS"
    ///   "Year 12 Physics"  -> "Y12 PHYSICS"
    /// Anything else is upper-cased and truncated to 12 chars with an ellipsis.
    static func compactClass(_ s: String) -> String {
        guard !s.isEmpty else { return "" }
        let up = s.uppercased()
        // "YEAR NN SUBJECT" -> "YNN SUBJECT"
        if let m = up.range(of: #"^YEAR (\d{1,2}) (.+)$"#, options: .regularExpression) {
            let whole = String(up[m])
            let parts = whole.components(separatedBy: " ")
            if parts.count >= 3 {
                let subject = parts[2...].joined(separator: " ")
                return "Y\(parts[1]) \(subject)"
            }
        }
        if up.count > 12 {
            return String(up.prefix(11)) + "…"
        }
        return up
    }

    // MARK: Inline primitives (card-padded)

    func addLabel(_ text: String) {
        y += 5
        let attr = Self.attrString(text.uppercased(),
                                   font: .systemFont(ofSize: 8, weight: .semibold),
                                   color: softLabel, kern: 0.6)
        drawPadded(attr); y += 1
    }

    func addItalic(_ text: String) {
        let font = NSFontManager.shared.convert(.systemFont(ofSize: 10), toHaveTrait: .italicFontMask)
        let attr = Self.attrString(text, font: font, color: softLabel)
        drawPadded(attr); y += 2
    }

    func addBullets(_ items: [String]) {
        for item in items {
            let marker = Self.attrString("•  ", font: .systemFont(ofSize: 11), color: softLabel)
            let text = Self.attrString(item, font: .systemFont(ofSize: 11), color: .black)
            let full = NSMutableAttributedString(attributedString: marker)
            full.append(text)
            drawPadded(full, leftIndent: 8)
        }
    }

    func addResourceLine(name: String, path: String) {
        let nameAttr = Self.attrString("•  \(name)", font: .systemFont(ofSize: 10, weight: .medium), color: .black)
        drawPadded(nameAttr, leftIndent: 8)
        let pathAttr = Self.attrString(path, font: Self.monoFont(size: 8), color: softLabel)
        drawPadded(pathAttr, leftIndent: 20)
    }

    func addSourceLine(_ text: String) {
        y += 4
        let attr = Self.attrString(text, font: Self.monoFont(size: 7.5), color: softLabel)
        drawPadded(attr)
    }

    func addMarkdown(_ md: String, compact: Bool) {
        let fontSize: CGFloat = compact ? 10 : 11
        let lines = md.split(separator: "\n", omittingEmptySubsequences: false)
        var buffer: [String] = []

        func flushPara() {
            let text = buffer.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            buffer.removeAll()
            if text.isEmpty { return }
            let attr = Self.markdownAttr(text, baseSize: fontSize)
            drawPadded(attr); y += 3
        }

        for raw in lines {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { flushPara(); continue }
            if let (level, head) = Self.parseHeading(trimmed) {
                flushPara()
                let size: CGFloat
                let weight: NSFont.Weight
                switch level {
                case 1: size = fontSize + 5; weight = .bold
                case 2: size = fontSize + 3; weight = .semibold
                case 3: size = fontSize + 1; weight = .semibold
                default: size = fontSize; weight = .semibold
                }
                let attr = Self.attrString(head, font: .systemFont(ofSize: size, weight: weight), color: .black)
                y += 5
                drawPadded(attr)
                y += 2
                continue
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                flushPara()
                let item = String(trimmed.dropFirst(2))
                let marker = Self.attrString("•  ", font: .systemFont(ofSize: fontSize), color: softLabel)
                let body = Self.markdownAttr(item, baseSize: fontSize)
                let full = NSMutableAttributedString(attributedString: marker)
                full.append(body)
                drawPadded(full, leftIndent: 8)
                continue
            }
            buffer.append(trimmed)
        }
        flushPara()
    }

    func addSpacer(_ h: CGFloat) { y += h }

    // MARK: - Drawing primitives

    /// Draw inside the card's inner-padding (16pt horizontal).
    private func drawPadded(_ attr: NSAttributedString, leftIndent: CGFloat = 0) {
        drawInner(attr, insetLeft: 16 + leftIndent, insetRight: 16)
    }

    /// Draw at the outer margin (for document-level stuff like the title).
    private func draw(_ attr: NSAttributedString, leftIndent: CGFloat = 0) {
        drawInner(attr, insetLeft: leftIndent, insetRight: 0)
    }

    private func drawInner(_ attr: NSAttributedString, insetLeft: CGFloat, insetRight: CGFloat) {
        let width = contentWidth - insetLeft - insetRight
        let size = attr.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let height = ceil(size.height)
        if y + height + 2 > pageSize.height - margin {
            // page break — close current card frame first if open so we don't
            // draw an unfinished border, then reopen on next page
            let hadCard = cardStartY != nil
            if hadCard {
                // flush current card: close box up to y, start new one at top of next page
                closeOpenCardPartial()
            }
            newPage()
            if hadCard { cardStartY = y - 10 /* re-start inner top padding */ }
        }
        guard let ctx = ctx else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        let frame = CGRect(x: margin + insetLeft, y: y, width: width, height: height)
        attr.draw(with: frame, options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.restoreGraphicsState()
        y += height + 1
    }

    /// When paginating mid-card, draw the partial card's border on the way out.
    private func closeOpenCardPartial() {
        guard let ctx = ctx, let startY = cardStartY else { return }
        let rect = CGRect(x: margin,
                          y: startY,
                          width: contentWidth,
                          height: y - startY + 6)
        ctx.saveGState()
        ctx.setStrokeColor(softBorder.cgColor)
        ctx.setLineWidth(0.5)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 5, cornerHeight: 5, transform: nil))
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func drawFooter() {
        guard let ctx = ctx else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        let text = "Page \(pageNumber)  ·  Generated \(Fmt.generated.string(from: Date()))  ·  Teaching Hub"
        let attr = Self.attrString(text, font: .systemFont(ofSize: 7.5), color: softLabel)
        // Flipped context — footer sits near the bottom of the page.
        let footerY = pageSize.height - margin / 2
        attr.draw(at: CGPoint(x: margin, y: footerY))
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: - String helpers

    static func parseHeading(_ line: String) -> (Int, String)? {
        var hashes = 0
        var idx = line.startIndex
        while idx < line.endIndex, line[idx] == "#", hashes < 6 {
            hashes += 1
            idx = line.index(after: idx)
        }
        guard hashes >= 1, idx < line.endIndex, line[idx] == " " else { return nil }
        let text = String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
        return (hashes, text)
    }

    static func attrString(_ s: String, font: NSFont, color: NSColor, kern: CGFloat = 0) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        style.lineSpacing = 2
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: style,
        ]
        if kern != 0 { attrs[.kern] = kern }
        return NSAttributedString(string: s, attributes: attrs)
    }

    static func markdownAttr(_ text: String, baseSize: CGFloat) -> NSAttributedString {
        let regularFont = NSFont.systemFont(ofSize: baseSize)
        let boldFont = NSFontManager.shared.convert(regularFont, toHaveTrait: .boldFontMask)
        let italicFont = NSFontManager.shared.convert(regularFont, toHaveTrait: .italicFontMask)
        let codeFont = NSFont.monospacedSystemFont(ofSize: baseSize - 1, weight: .regular)
        let paraStyle: NSParagraphStyle = {
            let p = NSMutableParagraphStyle()
            p.lineBreakMode = .byWordWrapping
            p.lineSpacing = 2
            return p
        }()

        enum Rule { case bold, italic, code, link }
        struct Match { let range: Range<String.Index>; let display: String; let font: NSFont; let url: URL?; let kind: Rule }

        func scan(_ s: String) -> [Match] {
            var out: [Match] = []
            var i = s.startIndex
            while i < s.endIndex {
                let c = s[i]
                let rest = s[i...]

                var matched = false
                for marker in ["**", "__"] {
                    if rest.hasPrefix(marker) {
                        let afterOpen = s.index(i, offsetBy: marker.count)
                        if let closeRange = s.range(of: marker, range: afterOpen..<s.endIndex),
                           closeRange.lowerBound != afterOpen {
                            let inner = String(s[afterOpen..<closeRange.lowerBound])
                            out.append(Match(range: i..<closeRange.upperBound, display: inner,
                                             font: boldFont, url: nil, kind: .bold))
                            i = closeRange.upperBound
                            matched = true
                            break
                        }
                    }
                }
                if matched { continue }

                if c == "*" || c == "_" {
                    let marker = String(c)
                    let next = s.index(after: i)
                    if next < s.endIndex, s[next] != c {
                        if let closeRange = s.range(of: marker, range: next..<s.endIndex) {
                            let inner = String(s[next..<closeRange.lowerBound])
                            if !inner.isEmpty, !inner.contains("\n") {
                                out.append(Match(range: i..<closeRange.upperBound, display: inner,
                                                 font: italicFont, url: nil, kind: .italic))
                                i = closeRange.upperBound
                                continue
                            }
                        }
                    }
                }
                if c == "`" {
                    let next = s.index(after: i)
                    if let closeRange = s.range(of: "`", range: next..<s.endIndex) {
                        let inner = String(s[next..<closeRange.lowerBound])
                        out.append(Match(range: i..<closeRange.upperBound, display: inner,
                                         font: codeFont, url: nil, kind: .code))
                        i = closeRange.upperBound
                        continue
                    }
                }
                if c == "[" {
                    if let closeBracket = s.range(of: "]", range: i..<s.endIndex) {
                        let afterClose = closeBracket.upperBound
                        if afterClose < s.endIndex, s[afterClose] == "(" {
                            let parenStart = s.index(after: afterClose)
                            if let parenClose = s.range(of: ")", range: parenStart..<s.endIndex) {
                                let display = String(s[s.index(after: i)..<closeBracket.lowerBound])
                                let urlStr = String(s[parenStart..<parenClose.lowerBound])
                                out.append(Match(range: i..<parenClose.upperBound, display: display,
                                                 font: regularFont, url: URL(string: urlStr), kind: .link))
                                i = parenClose.upperBound
                                continue
                            }
                        }
                    }
                }
                i = s.index(after: i)
            }
            return out
        }

        let matches = scan(text).sorted { $0.range.lowerBound < $1.range.lowerBound }
        let result = NSMutableAttributedString()
        var cursor = text.startIndex
        for m in matches {
            if m.range.lowerBound > cursor {
                let before = String(text[cursor..<m.range.lowerBound])
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: regularFont, .foregroundColor: NSColor.black, .paragraphStyle: paraStyle
                ]
                result.append(NSAttributedString(string: before, attributes: attrs))
            }
            var attrs: [NSAttributedString.Key: Any] = [
                .font: m.font, .foregroundColor: NSColor.black, .paragraphStyle: paraStyle
            ]
            if m.kind == .link, let url = m.url {
                attrs[.link] = url
                attrs[.foregroundColor] = NSColor.systemBlue
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            if m.kind == .code {
                attrs[.backgroundColor] = NSColor.gray.withAlphaComponent(0.1)
            }
            result.append(NSAttributedString(string: m.display, attributes: attrs))
            cursor = m.range.upperBound
        }
        if cursor < text.endIndex {
            let tail = String(text[cursor...])
            let attrs: [NSAttributedString.Key: Any] = [
                .font: regularFont, .foregroundColor: NSColor.black, .paragraphStyle: paraStyle
            ]
            result.append(NSAttributedString(string: tail, attributes: attrs))
        }
        return result
    }

    static func monoFont(size: CGFloat) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
}
