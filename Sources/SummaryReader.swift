import SwiftUI
import AppKit

// The strip under the reader header: Transcript | Summary, the two AI tools (Find key moments and
// Summarize), and their progress. Both run one local pass at a time, so the bar shows whichever is active.
struct SummaryBar: View {
    let transcript: URL
    @ObservedObject var summaries: SummaryCenter
    let hasSummary: Bool
    @Binding var showSummary: Bool
    var paths = AppPaths()
    var aiMarkerCount = 0
    var requested: () -> Void = {}
    @AppStorage(SummarySettings.providerKey) private var providerRaw = SummaryProvider.off.rawValue

    private var provider: SummaryProvider { SummaryProvider(rawValue: providerRaw) ?? .off }
    private var status: SummaryCenter.Status? { summaries.status(for: transcript) }
    private var moments: SummaryCenter.Status? { summaries.momentStatus(for: transcript) }
    private var note: SummaryCenter.Note? { summaries.momentNote(for: transcript) }
    private var cloudName: String { provider.title.replacingOccurrences(of: " API key", with: "") }

    var body: some View {
        // Full labels when the reader has room. Narrower readers keep the same actions as icons, each with its tip.
        ViewThatFits(in: .horizontal) {
            bar(compact: false)
            bar(compact: true)
        }
        .padding(.horizontal, 22).padding(.vertical, 8)
    }

    private func bar(compact: Bool) -> some View {
        HStack(spacing: 10) {
            if hasSummary {
                HStack(spacing: 2) {
                    Button { showSummary = false } label: { Text("Transcript") }
                        .buttonStyle(ReaderToggleStyle(selected: !showSummary))
                        .tip("Read transcript")
                    Button { showSummary = true } label: { Text("Summary") }
                        .buttonStyle(ReaderToggleStyle(selected: showSummary))
                        .tip("Read summary")
                }
                .padding(2).background(Theme.surface.opacity(0.68), in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.line, lineWidth: 1))
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Show transcript or summary")
            } else if status == nil, moments == nil, summaries.error(for: transcript) == nil, note == nil {
                Text("No summary yet").font(Theme.text(11.5)).foregroundStyle(Theme.muted)
            }
            statusText
            Spacer(minLength: 0)
            if aiMarkerCount > 0, moments == nil {
                Button(action: removeAIMarkers) {
                    Image(systemName: "bookmark.slash").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(IconButtonStyle(size: 28))
                .tip("Remove AI markers")
                .accessibilityLabel("Remove AI markers")
            }
            findButton(compact: compact)
            summarizeButton(compact: compact)
        }
    }

    @ViewBuilder private var statusText: some View {
        if let moments {
            switch moments {
            case .queued:
                label("Find key moments queued", color: Theme.muted)
            case .running(let step, let total):
                label("Finding moments · \(step) of \(total)", color: Theme.muted)
            case .waiting(let reason):
                label("Paused. \(reason)", color: Theme.warmText)
            }
        } else {
            switch status {
            case .queued?:
                label("Queued", color: Theme.muted)
            case .running(let step, let total)?:
                label(total > 1 ? "Part \(step) of \(total)" : "Writing summary…", color: Theme.muted)
            case .waiting(let reason)?:
                label("Paused. \(reason)", color: Theme.warmText)
            case nil:
                if let error = summaries.error(for: transcript) {
                    label(error, color: Theme.validationText)
                } else if let note {
                    label(note.text, color: note.failed ? Theme.validationText : Theme.muted)
                }
            }
        }
    }
    private func label(_ text: String, color: Color) -> some View {
        Text(text).font(Theme.text(11.5)).foregroundStyle(color).lineLimit(1).truncationMode(.tail)
            .tip(text, edge: .bottom)
    }

    @ViewBuilder private func findButton(compact: Bool) -> some View {
        if moments != nil {
            Button("Cancel") { summaries.cancelMoments(transcript) }
                .buttonStyle(PillButtonStyle(kind: .quiet, height: 28, fullWidth: false, horizontalPadding: 12))
                .tip("Stop finding key moments")
                .accessibilityLabel("Cancel finding key moments")
        } else {
            Button(action: findKeyMoments) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkle.magnifyingglass").font(.system(size: 11, weight: .semibold))
                    if !compact { Text("Find key moments") }
                }
            }
            .buttonStyle(PillButtonStyle(kind: .quiet, height: 28, fullWidth: false, horizontalPadding: compact ? 10 : 12))
            .tip(findTip)
            .accessibilityLabel("Find key moments")
        }
    }
    private func summarizeButton(compact: Bool) -> some View {
        Button(action: summarize) {
            HStack(spacing: 6) {
                if status != nil {
                    ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14)
                } else {
                    Image(systemName: hasSummary ? "arrow.clockwise" : "sparkles").font(.system(size: 11, weight: .semibold))
                }
                if !compact { Text(provider == .off ? "Turn on summaries in Settings" : status != nil ? "Summarizing" : (hasSummary ? "Summarize again" : "Summarize")) }
            }
        }
        .buttonStyle(PillButtonStyle(kind: .quiet, height: 28, fullWidth: false, horizontalPadding: compact ? 10 : 12))
        .disabled(status != nil)
        .tip(buttonTip)
        .accessibilityLabel(provider == .off ? "Turn on summaries in Settings" : hasSummary ? "Summarize again" : "Summarize")
    }
    private var findTip: String {
        if provider == .off { return "Turn on summaries in Settings" }
        return provider.staysOnMac ? "Find key moments on this Mac" : "Find key moments with \(cloudName)"
    }
    private var buttonTip: String {
        if provider == .off { return "Turn on summaries in Settings" }
        if status != nil { return "Summary in progress" }
        return provider.staysOnMac ? "Summarize on this Mac" : "Summarize with \(cloudName)"
    }

    private func summarize() {
        guard provider != .off else { SummarySettingsWindow.open(); return }
        requested()
        summaries.summarize(transcript)
    }
    // Off explains itself in the bar and opens Settings. Cloud and CLI providers ask once before the first run.
    private func findKeyMoments() {
        guard provider != .off else {
            summaries.findMoments(transcript, paths: paths)
            SummarySettingsWindow.open()
            return
        }
        guard confirmedOffMac() else { return }
        summaries.findMoments(transcript, paths: paths)
    }
    private func confirmedOffMac() -> Bool {
        guard !provider.staysOnMac else { return true }
        let key = "keyMoments.confirmed.\(provider.rawValue)"
        if UserDefaults.standard.bool(forKey: key) { return true }
        let alert = NSAlert()
        alert.messageText = "Send this transcript to \(cloudName)?"
        alert.informativeText = "Finding key moments sends the transcript text to \(cloudName), which runs outside this Mac. Nosy asks once for each provider. Built in and local models keep the text on this Mac."
        alert.addButton(withTitle: "Find key moments")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        UserDefaults.standard.set(true, forKey: key)
        return true
    }
    private func removeAIMarkers() {
        do {
            try KeyMomentStore.removeAll(transcript: transcript, paths: paths)
            summaries.markersChanged()
        } catch { NSAlert(error: error).runModal() }
    }
}

struct ReaderToggleStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View { ToggleBody(configuration: configuration, selected: selected) }
    private struct ToggleBody: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        @Environment(\.isEnabled) private var enabled
        @Environment(\.isFocused) private var focused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovering = false
        var body: some View {
            configuration.label
                .font(Theme.text(11.5, .medium))
                .foregroundStyle(selected ? Theme.ink : Theme.muted)
                .padding(.horizontal, 11).frame(height: 24)
                .background(selected ? Theme.raised : (hovering && enabled ? Theme.surface : .clear), in: Capsule())
                .overlay(Capsule().strokeBorder(selected ? Theme.line : .clear, lineWidth: 1))
                .scaleEffect(configuration.isPressed && enabled && !reduceMotion ? 0.97 : 1)
                .opacity(enabled ? 1 : 0.42)
                .overlay(Capsule().strokeBorder(focused ? Theme.accentText : .clear, lineWidth: 2).padding(-2))
                .contentShape(Capsule())
                .onHover { inside in withAnimation(Motion.hover) { hovering = inside } }
                .animation(Motion.press, value: configuration.isPressed)
                .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }
}

// Renders the small Markdown subset summaries use: headings, bullets, numbered lists, bold and italics.
struct SummaryText: View {
    let markdown: String

    enum Line: Equatable {
        case heading(String), bullet(String), numbered(String, String), note(String), paragraph(String)
    }
    static func lines(_ markdown: String) -> [Line] {
        markdown.components(separatedBy: .newlines).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("# ") { return nil }
            if line.hasPrefix("#") { return .heading(line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)) }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") { return .bullet(String(line.dropFirst(2))) }
            if let dot = line.firstIndex(of: "."), dot > line.startIndex, line[..<dot].allSatisfy(\.isNumber),
               line[line.index(after: dot)...].first == " " {
                return .numbered(String(line[...dot]), line[line.index(after: dot)...].trimmingCharacters(in: .whitespaces))
            }
            if line.hasPrefix("_"), line.hasSuffix("_"), line.count > 2 { return .note(String(line.dropFirst().dropLast())) }
            return .paragraph(line)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(Self.lines(markdown).enumerated()), id: \.offset) { index, line in
                switch line {
                case .heading(let text):
                    Text(inline(text)).font(Theme.text(16, .semibold)).foregroundStyle(Theme.ink)
                        .padding(.top, index == 0 ? 0 : 10)
                        .accessibilityAddTraits(.isHeader)
                case .bullet(let text):
                    row("•", text)
                case .numbered(let number, let text):
                    row(number, text)
                case .note(let text):
                    Text(text).font(Theme.text(12)).foregroundStyle(Theme.muted)
                case .paragraph(let text):
                    Text(inline(text)).font(Theme.text(15)).foregroundStyle(Theme.ink).lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private func row(_ mark: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(mark).font(Theme.text(14, .medium)).foregroundStyle(Theme.accentText).monospacedDigit()
                .frame(minWidth: 14, alignment: .trailing)
                .accessibilityHidden(mark == "•")
            Text(inline(text)).font(Theme.text(15)).foregroundStyle(Theme.ink).lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}
