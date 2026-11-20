import Foundation
import SwiftUI

/// SwiftUI's built-in `AttributedString(markdown:)` handles bold/italic/links/inline code.
/// We add a small wrapper that strips fenced code blocks and headings into structured chunks
/// so we can render them with appropriate fonts.
enum MarkdownBlocks {
    enum Block {
        case paragraph(AttributedString)
        case heading(level: Int, text: AttributedString)
        case bullet([AttributedString])
        case orderedList([AttributedString])
        case quote([Block])
        case code(String)
        case rule
    }

    static func parse(_ src: String) -> [Block] {
        var blocks: [Block] = []
        let lines = src.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var i = 0
        var inFence = false
        var fenceBuf: [String] = []

        while i < lines.count {
            let line = lines[i]
            if inFence {
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    blocks.append(.code(fenceBuf.joined(separator: "\n")))
                    fenceBuf = []
                    inFence = false
                } else {
                    fenceBuf.append(line)
                }
                i += 1
                continue
            }
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inFence = true
                i += 1
                continue
            }
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                i += 1
                continue
            }
            if let m = line.range(of: #"^\s*(-{3,}|_{3,}|\*{3,})\s*$"#, options: .regularExpression),
               m == line.startIndex..<line.endIndex {
                blocks.append(.rule)
                i += 1
                continue
            }
            // Heading
            if let m = line.range(of: #"^(#{1,6})\s+(.+?)\s*#*\s*$"#, options: .regularExpression) {
                let raw = String(line[m])
                let hashCount = raw.prefix(while: { $0 == "#" }).count
                let title = raw.drop(while: { $0 == "#" || $0 == " " || $0 == "\t" })
                blocks.append(.heading(level: hashCount, text: attributed(String(title))))
                i += 1
                continue
            }
            // Blockquote
            if line.hasPrefix(">") {
                var quoteLines: [String] = []
                while i < lines.count && lines[i].hasPrefix(">") {
                    let stripped = lines[i].dropFirst().drop(while: { $0 == " " })
                    quoteLines.append(String(stripped))
                    i += 1
                }
                let inner = parse(quoteLines.joined(separator: "\n"))
                blocks.append(.quote(inner))
                continue
            }
            // Lists
            if let _ = line.range(of: #"^\s*([-*+])\s+"#, options: .regularExpression) {
                var items: [AttributedString] = []
                while i < lines.count, let _ = lines[i].range(of: #"^\s*([-*+])\s+"#, options: .regularExpression) {
                    let stripped = lines[i].replacingOccurrences(of: #"^\s*([-*+])\s+"#, with: "", options: .regularExpression)
                    items.append(attributed(stripped))
                    i += 1
                }
                blocks.append(.bullet(items))
                continue
            }
            if let _ = line.range(of: #"^\s*\d+\.\s+"#, options: .regularExpression) {
                var items: [AttributedString] = []
                while i < lines.count, let _ = lines[i].range(of: #"^\s*\d+\.\s+"#, options: .regularExpression) {
                    let stripped = lines[i].replacingOccurrences(of: #"^\s*\d+\.\s+"#, with: "", options: .regularExpression)
                    items.append(attributed(stripped))
                    i += 1
                }
                blocks.append(.orderedList(items))
                continue
            }
            // Paragraph: gather lines until blank/heading/list/quote/fence
            var paraLines = [line]
            i += 1
            while i < lines.count {
                let nxt = lines[i]
                let t = nxt.trimmingCharacters(in: .whitespaces)
                if t.isEmpty { break }
                if t.hasPrefix("#") { break }
                if t.hasPrefix("```") { break }
                if t.hasPrefix(">") { break }
                if nxt.range(of: #"^\s*([-*+])\s+"#, options: .regularExpression) != nil { break }
                if nxt.range(of: #"^\s*\d+\.\s+"#, options: .regularExpression) != nil { break }
                paraLines.append(nxt)
                i += 1
            }
            blocks.append(.paragraph(attributed(paraLines.joined(separator: " "))))
        }
        if inFence && !fenceBuf.isEmpty {
            blocks.append(.code(fenceBuf.joined(separator: "\n")))
        }
        return blocks
    }

    private static func attributed(_ s: String) -> AttributedString {
        // Try SwiftUI's built-in markdown parser first
        if let attr = try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return attr
        }
        return AttributedString(s)
    }
}

/// Render parsed blocks into a SwiftUI view. Used inside entry cards and timeline.
struct MarkdownView: View {
    let source: String
    private var blocks: [MarkdownBlocks.Block] { MarkdownBlocks.parse(source) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(0..<blocks.count, id: \.self) { idx in
                blockView(blocks[idx])
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlocks.Block) -> some View {
        switch block {
        case .paragraph(let s):
            Text(s)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .heading(let lvl, let s):
            Text(s)
                .font(headingFont(level: lvl))
                .fontWeight(.semibold)
                .padding(.top, 2)
        case .bullet(let items):
            VStack(alignment: .leading, spacing: 2) {
                ForEach(0..<items.count, id: \.self) { i in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•").foregroundStyle(.secondary)
                        Text(items[i]).font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .orderedList(let items):
            VStack(alignment: .leading, spacing: 2) {
                ForEach(0..<items.count, id: \.self) { i in
                    HStack(alignment: .top, spacing: 6) {
                        Text("\(i + 1).").foregroundStyle(.secondary)
                        Text(items[i]).font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .quote(let inner):
            HStack(spacing: 8) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.3))
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(0..<inner.count, id: \.self) { i in
                        AnyView(blockView(inner[i]))
                    }
                }
            }
        case .code(let s):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(s)
                    .font(.system(size: 11, design: .monospaced))
                    .padding(8)
            }
            .background(Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 4))
        case .rule:
            Divider()
        }
    }

    private func headingFont(level: Int) -> Font {
        switch level {
        case 1: return .system(size: 16)
        case 2: return .system(size: 14)
        default: return .system(size: 13)
        }
    }
}
