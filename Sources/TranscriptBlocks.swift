import Foundation

// Keep displayed paragraphs tied to UTF-16 ranges in the original Markdown.
struct TranscriptBlock {
    enum Content { case title(String), meta([String]), heading(String), paragraph(String) }
    let content: Content
    let offset: Int

    func sourceRange(_ selection: NSRange) -> NSRange? {
        guard case .paragraph(let text) = content, selection.location >= 0,
              selection.length > 0, selection.location <= text.utf16.count,
              selection.length <= text.utf16.count - selection.location else { return nil }
        return NSRange(location: offset + selection.location, length: selection.length)
    }
    static func parse(_ markdown: String) -> [Self] {
        var result: [Self] = [], offset = 0
        for chunk in markdown.components(separatedBy: "\n\n") {
            defer { offset += chunk.utf16.count + 2 }
            let lines = chunk.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard let first = lines.first else { continue }
            let content: Content
            if first.hasPrefix("# ") { content = .title(String(first.dropFirst(2))) }
            else if first.hasPrefix("## ") { content = .heading(String(first.dropFirst(3))) }
            else if lines.allSatisfy({ $0.hasPrefix("- ") }) { content = .meta(lines.map { String($0.dropFirst(2)) }) }
            else { content = .paragraph(chunk) }
            result.append(Self(content: content, offset: offset))
        }
        return result
    }
}
