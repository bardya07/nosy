import AppKit
import SwiftUI

// Native selection supplies an exact source range for the correction action.
struct FixWordView: NSViewRepresentable {
    let markdown: String
    let correct: (NSRange, String) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let view = CorrectionTextView()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 28, height: 22)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? CorrectionTextView else { return }
        view.correct = correct
        guard view.string != markdown else { return }
        // Retain raw-source offsets; styling keeps the editable source and selection identical.
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5
        let text = NSMutableAttributedString(string: markdown, attributes: [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph])
        let ns = markdown as NSString
        if let regex = try? NSRegularExpression(pattern: #"(?m)^#{1,2} .+$"#) {
            for match in regex.matches(in: markdown, range: NSRange(location: 0, length: ns.length)) {
                text.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: ns.substring(with: match.range).hasPrefix("##") ? 13 : 24), range: match.range)
            }
        }
        view.textStorage?.setAttributedString(text)
        view.setAccessibilityLabel("Transcript. Select a word and open the context menu to fix its spelling.")
    }
}

private final class CorrectionTextView: NSTextView {
    var correct: ((NSRange, String) -> Void)?
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let item = NSMenuItem(title: "Fix this word…", action: #selector(fixWord), keyEquivalent: "")
        item.target = self
        item.isEnabled = selectedRange().length > 0 && selectedRange().length <= 100
        menu.insertItem(item, at: 0)
        return menu
    }
    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(fixWord) { return selectedRange().length > 0 && selectedRange().length <= 100 }
        return super.validateMenuItem(menuItem)
    }
    @objc private func fixWord() {
        let range = selectedRange()
        guard range.length > 0, range.length <= 100, NSMaxRange(range) <= (string as NSString).length else { return }
        let source = (string as NSString).substring(with: range)
        let alert = NSAlert()
        alert.messageText = "Fix this word"
        alert.informativeText = "Correct this spelling and remember it in this course's vocabulary."
        let field = NSTextField(string: source)
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Save correction")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let replacement = Core.collapseWhitespace(field.stringValue)
        guard !replacement.isEmpty, replacement.utf16.count <= 100 else { return }
        correct?(range, replacement)
    }
}
