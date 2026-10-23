import AppKit
import SwiftUI

// Native selection supplies an exact source range for the correction action.
struct FixWordView: NSViewRepresentable {
    let markdown: String
    let correct: (NSRange, String) -> Void

    func makeNSView(context: Context) -> NSTextView {
        let view = CorrectionTextView()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        return view
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NSTextView, context: Context) -> CGSize? {
        let proposedWidth = proposal.width ?? 640
        let width = proposedWidth.isFinite ? max(1, proposedWidth) : 640
        guard let container = view.textContainer, let layout = view.layoutManager else { return nil }
        view.setFrameSize(NSSize(width: width, height: view.frame.height))
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        return CGSize(width: width, height: ceil(layout.usedRect(for: container).height))
    }
    func updateNSView(_ nsView: NSTextView, context: Context) {
        guard let view = nsView as? CorrectionTextView else { return }
        view.correct = correct
        guard view.string != markdown else { return }
        // Retain raw-source offsets; styling keeps the editable source and selection identical.
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5
        let body = NSFont(name: "Inter-Regular", size: 15) ?? NSFont.systemFont(ofSize: 15)
        let text = NSMutableAttributedString(string: markdown, attributes: [.font: body, .foregroundColor: NSColor(Theme.ink), .paragraphStyle: paragraph])
        let ns = markdown as NSString
        if let regex = try? NSRegularExpression(pattern: #"(?m)^#{1,2} .+$"#) {
            for match in regex.matches(in: markdown, range: NSRange(location: 0, length: ns.length)) {
                let size: CGFloat = ns.substring(with: match.range).hasPrefix("##") ? 13 : 24
                let font = NSFont(name: "Inter-Regular", size: size).map { NSFontManager.shared.convert($0, toHaveTrait: .boldFontMask) } ?? NSFont.boldSystemFont(ofSize: size)
                text.addAttribute(.font, value: font, range: match.range)
            }
        }
        if let markers = try? NSRegularExpression(pattern: #"(?m)^#{1,2} +"#) {
            for match in markers.matches(in: markdown, range: NSRange(location: 0, length: ns.length)) {
                text.addAttributes([.font: NSFont.systemFont(ofSize: 0.1), .foregroundColor: NSColor.clear], range: match.range)
            }
        }
        if let metadata = try? NSRegularExpression(pattern: #"(?m)^- .+$"#) {
            for match in metadata.matches(in: markdown, range: NSRange(location: 0, length: ns.length)) {
                text.addAttributes([.font: NSFont(name: "JetBrainsMono-Regular", size: 12) ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor(Theme.muted)], range: match.range)
            }
        }
        view.textStorage?.setAttributedString(text)
        view.invalidateIntrinsicContentSize()
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
        alert.informativeText = "Correct this spelling and remember it in this folder's vocabulary."
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
