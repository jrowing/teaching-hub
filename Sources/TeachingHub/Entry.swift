import Foundation

struct Entry: Identifiable, Hashable {
    let id: String          // relative path used as stable id
    let url: URL            // the lesson.md file itself
    let folderURL: URL      // the folder containing it (for folder-per-lesson); == url.deletingLastPathComponent() for flat files
    let relpath: String
    let title: String
    let date: Date
    let endDate: Date?
    let hasTime: Bool
    let tags: [String]
    let body: String                  // body without ## Requirements section
    let bodyFull: String              // body including ## Requirements
    let requirements: [String]
    let frontMatter: [String: String]
    let lastModified: Date
    let resources: [Resource]         // sibling files of the .md (empty for flat lessons)
    let classSlug: String?            // top-level folder name under the root — treated as the class

    static func == (lhs: Entry, rhs: Entry) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// A file attached to a lesson — a PowerPoint, PDF, image, worksheet, anything
/// that lives in the same folder as the lesson.md file.
struct Resource: Identifiable, Hashable {
    let id: String          // file path, stable id
    let url: URL
    let name: String        // filename including extension
    let ext: String         // lowercased extension
    let size: Int64         // in bytes

    /// A one-word category for picking an icon.
    enum Kind {
        case slides, document, spreadsheet, pdf, image, video, audio, archive, text, other
    }
    var kind: Kind {
        switch ext {
        case "pptx", "ppt", "key", "odp": return .slides
        case "docx", "doc", "odt", "pages", "rtf": return .document
        case "xlsx", "xls", "numbers", "csv", "tsv", "ods": return .spreadsheet
        case "pdf": return .pdf
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp", "svg": return .image
        case "mp4", "mov", "m4v", "webm", "avi", "mkv": return .video
        case "mp3", "m4a", "wav", "aac", "flac", "ogg": return .audio
        case "zip", "tar", "gz", "7z", "rar": return .archive
        case "txt", "md", "markdown", "mdown": return .text
        default: return .other
        }
    }

    /// SF Symbol name for the resource icon.
    var symbolName: String {
        switch kind {
        case .slides: return "rectangle.on.rectangle.angled"
        case .document: return "doc.text"
        case .spreadsheet: return "tablecells"
        case .pdf: return "doc.richtext"
        case .image: return "photo"
        case .video: return "play.rectangle"
        case .audio: return "waveform"
        case .archive: return "doc.zipper"
        case .text: return "doc.plaintext"
        case .other: return "doc"
        }
    }
}
