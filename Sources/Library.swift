import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

struct TranscriptItem: Identifiable, Hashable {
    let url: URL
    let lecture: String
    let session: String
    let recorded: Date
    let text: String
    var id: URL { url }
}

// Reads the transcripts folder (one subfolder per lecture, one .md per session) once per
// reload and keeps the text in memory, so search never touches the disk while typing.
@MainActor
final class TranscriptLibrary: ObservableObject {
    @Published private(set) var items: [TranscriptItem] = []
    @Published private(set) var unfinished: [SessionRecord] = []
    @Published var selection: URL?
    @Published var query = "" { didSet { keepSelectionVisible() } }

    func reload(paths: AppPaths) {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .creationDateKey]
        let root = paths.transcripts
        let lectures = (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        items = lectures.flatMap { folder -> [TranscriptItem] in
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return [] }
            let files = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
            return files.filter { $0.pathExtension.lowercased() == "md" }.map { url in
                // Creation date stays put when a transcript is edited elsewhere, so the order doesn't jump.
                TranscriptItem(url: url, lecture: folder.lastPathComponent, session: url.deletingPathExtension().lastPathComponent,
                               recorded: (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast,
                               text: (try? String(contentsOf: url, encoding: .utf8)) ?? "")
            }
        }.sorted { $0.recorded > $1.recorded }
        unfinished = Core.unfinished(paths: paths)
        keepSelectionVisible()
    }
    var selected: TranscriptItem? { items.first { $0.url == selection } }
    var filtered: [TranscriptItem] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return items }
        return items.filter {
            $0.lecture.localizedCaseInsensitiveContains(needle) || $0.session.localizedCaseInsensitiveContains(needle)
                || $0.text.localizedCaseInsensitiveContains(needle)
        }
    }
    // The order rows appear in the sidebar, for arrow-key navigation.
    var ordered: [TranscriptItem] { grouped.flatMap(\.items) }
    var grouped: [(lecture: String, items: [TranscriptItem])] {
        let groups = Dictionary(grouping: filtered, by: \.lecture)
        return groups.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { ($0, groups[$0]!.sorted { $0.recorded > $1.recorded }) }
    }
    // Searching never leaves a hidden transcript open (where Trash would still act on it).
    private func keepSelectionVisible() {
        let visible = ordered
        if let selection, visible.contains(where: { $0.url == selection }) { return }
        selection = visible.first?.url
    }
    func move(_ step: Int) {
        let list = ordered
        guard !list.isEmpty else { return }
        let index = list.firstIndex { $0.url == selection } ?? (step > 0 ? -1 : list.count)
        selection = list[min(list.count - 1, max(0, index + step))].url
    }

    // Moves a transcript to the Trash (recoverable) and selects its neighbour.
    func trash(_ url: URL, paths: AppPaths) {
        let list = ordered
        let index = list.firstIndex(where: { $0.url == url })
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Couldn't move this transcript to the Trash"
            alert.runModal()
            return
        }
        let remaining = list.filter { $0.url != url }
        if selection == url {
            selection = index.flatMap { remaining.indices.contains($0) ? remaining[$0].url : remaining.last?.url }
        }
        reload(paths: paths)
    }
    func rename(_ item: TranscriptItem, paths: AppPaths) {
        let alert = NSAlert()
        alert.messageText = "Rename transcript"
        alert.informativeText = item.lecture
        let field = NSTextField(string: item.session)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let name = try Core.sanitize(field.stringValue)
            guard name != item.session else { return }
            let target = Core.uniqueTranscript(in: item.url.deletingLastPathComponent(), session: name)
            // Find the sidecar before moving, while it still matches the old path.
            let record = Core.record(forTranscript: item.url, paths: paths)
            try FileManager.default.moveItem(at: item.url, to: target)
            // Keep the recording's sidecar pointing at the transcript so playback still finds its audio.
            if var record {
                record.transcriptPath = target.path
                try? record.save(in: paths)
            }
            selection = target
            reload(paths: paths)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
    @discardableResult func save(_ text: String, to url: URL, paths: AppPaths) -> Bool {
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
            reload(paths: paths)
            return true
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
    }
}

struct LibraryView: View {
    @ObservedObject var model: AppModel
    @StateObject private var library = TranscriptLibrary()
    @Environment(\.openWindow) private var openWindow
    @FocusState private var focus: Focus?
    @State private var copied = false
    @State private var editing = false
    @State private var draft = ""
    enum Focus { case search, list }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Theme.line).frame(width: 1)
            reader
        }
        .frame(minWidth: 720, minHeight: 460)
        .background(Theme.background)
        .tint(Theme.accent)
        .onAppear {
            model.openWindow = openWindow
            reload()
            applyFocus()
        }
        .onChange(of: model.paths.transcripts) { reload() }
        .onChange(of: model.current?.transcriptPath) { reload() }
        .onChange(of: model.active?.id) { reload() }
        .onChange(of: model.libraryFocus) { reload(); applyFocus() }
        .onChange(of: library.selection) { editing = false }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in reload() }
    }
    private func reload() { library.reload(paths: model.paths) }
    private func applyFocus() {
        guard let url = model.libraryFocus else { return }
        library.query = ""
        library.selection = url
        model.libraryFocus = nil
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted).font(.system(size: 12, weight: .semibold))
                    .accessibilityHidden(true)
                TextField("", text: $library.query, prompt: Text("Search transcripts").foregroundStyle(Theme.faint))
                    .textFieldStyle(.plain).focused($focus, equals: .search)
                    .accessibilityLabel("Search transcripts")
                    .onKeyPress(.downArrow) { focus = .list; library.move(1); return .handled }
            }
            .fieldChrome(focused: focus == .search)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        if library.unfinished.contains(where: { !model.isLive($0.id) }), library.query.isEmpty { unfinishedSection }
                        ForEach(library.grouped, id: \.lecture) { group in
                            Text(group.lecture.uppercased()).font(Theme.label).kerning(0.8).foregroundStyle(Theme.muted)
                                .lineLimit(1).help(group.lecture)
                                .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 2)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(group.items) { item in row(item).id(item.url) }
                        }
                        if library.grouped.isEmpty {
                            Text(library.query.isEmpty ? "No transcripts yet.\nRecord a lecture and it shows up here." : "Nothing matches “\(library.query)”.")
                                .font(Theme.text(12.5)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity).padding(.top, 40)
                        }
                    }
                }
                .scrollIndicators(.never)
                .focusable()
                .focused($focus, equals: .list)
                .focusEffectDisabled()
                .onKeyPress(.downArrow) { library.move(1); return .handled }
                .onKeyPress(.upArrow) { library.move(-1); return .handled }
                .onChange(of: library.selection) { _, url in
                    if let url { withAnimation(Motion.hover) { proxy.scrollTo(url) } }
                }
            }
        }
        .padding(14)
        .disabled(editing)
        .opacity(editing ? 0.5 : 1)
        .help(editing ? "Save or cancel your edit first" : "")
        .frame(width: 250)
        .background(Theme.surface.opacity(0.5))
    }

    private func row(_ item: TranscriptItem) -> some View {
        Button { library.selection = item.url; focus = .list } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.session).font(Theme.text(13.5, .semibold)).lineLimit(1)
                Text(item.recorded.formatted(date: .abbreviated, time: .shortened)).font(Theme.text(11)).foregroundStyle(Theme.muted)
            }
        }
        .buttonStyle(RowButtonStyle(selected: library.selection == item.url))
        .help(item.session)
        .accessibilityLabel("\(item.lecture), \(item.session)")
        .accessibilityAddTraits(library.selection == item.url ? .isSelected : [])
        .contextMenu {
            Button("Rename…") { library.rename(item, paths: model.paths) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Divider()
            Button("Move to Trash", role: .destructive) { library.trash(item.url, paths: model.paths) }
        }
    }

    // Recordings without a transcript (failed, quit, or postponed) stay reachable here.
    private var unfinishedSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("UNFINISHED").font(Theme.label).kerning(0.8).foregroundStyle(Theme.coral)
                .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 2)
                .accessibilityAddTraits(.isHeader)
            ForEach(library.unfinished.filter { !model.isLive($0.id) }, id: \.id) { record in
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(record.lecture) · \(record.session)").font(Theme.text(12.5, .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                        Text(model.isQueued(record.id) ? (model.transcriptionPauseReason.map { "Paused — \($0)" } ?? "Transcribing…") : "\(Core.minutes(Core.audioDuration(id: record.id, paths: model.paths))) min · not transcribed")
                            .font(Theme.text(11)).foregroundStyle(Theme.muted)
                    }
                    Spacer(minLength: 0)
                    Button { model.retry(record) } label: { Image(systemName: "text.badge.plus") }
                        .buttonStyle(IconButtonStyle(size: 26))
                        .tip("Transcribe").accessibilityLabel("Transcribe \(record.lecture) \(record.session)")
                        .disabled(model.isQueued(record.id))
                    Button { model.deleteRecording(record); reload() } label: { Image(systemName: "trash") }
                        .buttonStyle(IconButtonStyle(size: 26, destructive: true))
                        .tip("Delete audio").accessibilityLabel("Delete audio for \(record.lecture) \(record.session)")
                        .disabled(model.isQueued(record.id))
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Theme.coral.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(.bottom, 6)
    }

    // MARK: Reader

    @ViewBuilder private var reader: some View {
        if let item = library.selected {
            VStack(spacing: 0) {
                readerHeader(item).zIndex(1)
                Rectangle().fill(Theme.line).frame(height: 1)
                if editing {
                    TextEditor(text: $draft)
                        .font(.system(size: 14, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 22).padding(.vertical, 16)
                        .accessibilityLabel("Transcript text")
                } else {
                    ScrollView {
                        TranscriptText(markdown: item.text)
                            .padding(.horizontal, 28).padding(.vertical, 22)
                            .frame(maxWidth: 640, alignment: .leading)
                            .frame(maxWidth: .infinity)
                    }
                }
                if let audio = audioURL(for: item) {
                    Rectangle().fill(Theme.line).frame(height: 1)
                    AudioStrip(url: audio).id(audio)
                }
            }
        } else {
            VStack(spacing: 10) {
                NosyMark(size: 48).opacity(0.85)
                Text("Pick a transcript").font(Theme.display(17, .bold)).foregroundStyle(Theme.ink)
                Text("Everything Nosy saves shows up here.").font(Theme.text(12.5)).foregroundStyle(Theme.muted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    private func audioURL(for item: TranscriptItem) -> URL? {
        Core.record(forTranscript: item.url, paths: model.paths).flatMap { AudioFiles.playable(id: $0.id, paths: model.paths) }
    }

    private func readerHeader(_ item: TranscriptItem) -> some View {
        HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.session).font(Theme.display(20, .bold)).foregroundStyle(Theme.ink).lineLimit(1).help(item.session)
                Text(item.lecture).font(Theme.text(12, .medium)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer()
            if editing {
                Button("Cancel") { editing = false }
                    .buttonStyle(PillButtonStyle(kind: .quiet, height: 30, fullWidth: false))
                    .keyboardShortcut(.cancelAction)
                Button("Save") { if library.save(draft, to: item.url, paths: model.paths) { editing = false } }
                    .buttonStyle(PillButtonStyle(kind: .primary, height: 30, fullWidth: false))
                    .keyboardShortcut("s", modifiers: .command)
            } else {
                Button { draft = item.text; editing = true } label: { Image(systemName: "pencil") }
                    .buttonStyle(IconButtonStyle(size: 32)).keyboardShortcut("e", modifiers: .command)
                    .tip("Edit  ⌘E").accessibilityLabel("Edit transcript")
                Button { copy(item.text) } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc").contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(IconButtonStyle(size: 32, active: copied))
                .tip(copied ? "Copied" : "Copy transcript").accessibilityLabel("Copy transcript")
                ExportMenu(item: item)
                Button { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } label: { Image(systemName: "folder") }
                    .buttonStyle(IconButtonStyle(size: 32)).tip("Show in Finder").accessibilityLabel("Show in Finder")
                OpenWithMenu(url: item.url)
                Button { library.trash(item.url, paths: model.paths) } label: { Image(systemName: "trash") }
                    .buttonStyle(IconButtonStyle(size: 32, destructive: true))
                    .keyboardShortcut(focus == .list ? KeyboardShortcut(.delete, modifiers: .command) : nil)
                    .tip("Move to Trash  ⌘⌫")
                    .accessibilityLabel("Move transcript to Trash")
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 14)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        withAnimation(Motion.press) { copied = true }
        Task { try? await Task.sleep(for: .seconds(1.4)); withAnimation(Motion.hover) { copied = false } }
    }
}

// Play the lecture back while reading, at study speeds.
private struct AudioStrip: View {
    let url: URL
    @StateObject private var player = StripPlayer()
    var body: some View {
        HStack(spacing: 12) {
            Button { player.toggle() } label: {
                Image(systemName: player.playing ? "pause.fill" : "play.fill").contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(RoundButtonStyle(size: 34))
            .accessibilityLabel(player.playing ? "Pause audio" : "Play audio")
            Text(Core.timer(player.time)).font(Theme.text(11.5, .semibold)).monospacedDigit().foregroundStyle(Theme.muted)
            Slider(value: Binding(get: { player.time }, set: { player.seek($0) }), in: 0...max(1, player.duration))
                .controlSize(.small)
                .accessibilityLabel("Playback position")
            Text(Core.timer(player.duration)).font(Theme.text(11.5, .semibold)).monospacedDigit().foregroundStyle(Theme.muted)
            Menu {
                ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                    Button(rateLabel(rate)) { player.rate = Float(rate) }
                }
            } label: {
                Text(rateLabel(Double(player.rate))).font(Theme.text(12, .semibold))
            }
            .menuStyle(.button).buttonStyle(PillButtonStyle(kind: .quiet, height: 26, fullWidth: false))
            .menuIndicator(.hidden).fixedSize()
            .tip("Playback speed", edge: .top)
            .accessibilityLabel("Playback speed")
        }
        .padding(.horizontal, 22).padding(.vertical, 10)
        .background(Theme.surface.opacity(0.6))
        .onAppear { player.load(url) }
        .onDisappear { player.stop() }
    }
    private func rateLabel(_ rate: Double) -> String { rate == 1 ? "1×" : "\(rate.formatted(.number.precision(.fractionLength(0...2))))×" }
}

@MainActor
private final class StripPlayer: ObservableObject {
    @Published var playing = false
    @Published var time: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var rate: Float = 1 { didSet { audio?.rate = rate } }
    private var audio: AVAudioPlayer?
    private var timer: Timer?
    func load(_ url: URL) {
        audio = try? AVAudioPlayer(contentsOf: url)
        audio?.enableRate = true
        audio?.prepareToPlay()
        duration = audio?.duration ?? 0
    }
    func toggle() {
        guard let audio else { return }
        if audio.isPlaying { audio.pause(); playing = false; timer?.invalidate() }
        else {
            audio.rate = rate
            audio.play(); playing = true
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let audio = self.audio else { return }
                    self.time = audio.currentTime
                    if !audio.isPlaying { self.playing = false; self.timer?.invalidate() }
                }
            }
        }
    }
    func seek(_ value: TimeInterval) { audio?.currentTime = value; time = value }
    func stop() { audio?.stop(); timer?.invalidate(); playing = false }
}

// Plain text, PDF and Print, for sharing outside Nosy.
private struct ExportMenu: View {
    let item: TranscriptItem
    var body: some View {
        Menu {
            Button("Save as Plain Text…") { saveText() }
            Button("Save as PDF…") { savePDF() }
            Divider()
            Button("Print…") { printOperation(saveTo: nil).run() }
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
        .menuStyle(.button)
        .buttonStyle(IconButtonStyle(size: 32))
        .menuIndicator(.hidden)
        .fixedSize()
        .tip("Export")
        .accessibilityLabel("Export transcript")
    }
    private func savePanel(_ type: UTType) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = "\(item.lecture) — \(item.session)"
        return panel.runModal() == .OK ? panel.url : nil
    }
    private func saveText() {
        guard let url = savePanel(.plainText) else { return }
        do { try Data(TranscriptExport.plainText(item.text).utf8).write(to: url, options: .atomic) }
        catch { NSAlert(error: error).runModal() }
    }
    private func savePDF() {
        guard let url = savePanel(.pdf) else { return }
        printOperation(saveTo: url).run()
    }
    private func printOperation(saveTo url: URL?) -> NSPrintOperation {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.topMargin = 54; info.bottomMargin = 54; info.leftMargin = 60; info.rightMargin = 60
        info.isVerticallyCentered = false
        info.horizontalPagination = .fit
        if let url {
            info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        }
        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        view.textStorage?.setAttributedString(TranscriptExport.attributed(item.text))
        view.isVerticallyResizable = true
        view.sizeToFit()
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.showsPrintPanel = url == nil
        operation.showsProgressPanel = false
        return operation
    }
}

enum TranscriptExport {
    static func plainText(_ markdown: String) -> String {
        lines(markdown).map(\.text).joined(separator: "\n\n")
    }
    static func attributed(_ markdown: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let body = NSFont(name: "Hanken Grotesk", size: 11.5) ?? .systemFont(ofSize: 11.5)
        let title = NSFont(name: "Bricolage Grotesque", size: 20).map { NSFontManager.shared.convert($0, toHaveTrait: .boldFontMask) } ?? .boldSystemFont(ofSize: 20)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.paragraphSpacing = 9
        for line in lines(markdown) {
            let attributes: [NSAttributedString.Key: Any]
            switch line.kind {
            case .title: attributes = [.font: title, .foregroundColor: NSColor.black, .paragraphStyle: paragraph]
            case .meta: attributes = [.font: body, .foregroundColor: NSColor.darkGray, .paragraphStyle: paragraph]
            case .heading: attributes = [.font: NSFont.boldSystemFont(ofSize: 10), .foregroundColor: NSColor.gray, .paragraphStyle: paragraph]
            case .body: attributes = [.font: body, .foregroundColor: NSColor.black, .paragraphStyle: paragraph]
            }
            result.append(NSAttributedString(string: line.text + "\n", attributes: attributes))
        }
        return result
    }
    private enum Kind { case title, meta, heading, body }
    private static func lines(_ markdown: String) -> [(kind: Kind, text: String)] {
        markdown.components(separatedBy: "\n").compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { return nil }
            if line.hasPrefix("## ") { return (.heading, String(line.dropFirst(3)).uppercased()) }
            if line.hasPrefix("# ") { return (.title, String(line.dropFirst(2))) }
            if line.hasPrefix("- ") { return (.meta, String(line.dropFirst(2))) }
            return (.body, line.replacingOccurrences(of: "_", with: ""))
        }
    }
}

// "Open with…": the system default for .md is often Xcode, so offer the choice, TextEdit first.
private struct OpenWithMenu: View {
    let url: URL
    var body: some View {
        Menu {
            ForEach(apps, id: \.self) { app in
                Button {
                    NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
                } label: {
                    Label { Text(FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")) }
                        icon: { Image(nsImage: icon(app)) }
                }
            }
        } label: {
            Image(systemName: "arrow.up.forward.app")
        }
        .menuStyle(.button)
        .buttonStyle(IconButtonStyle(size: 32))
        .menuIndicator(.hidden)
        .fixedSize()
        .tip("Open with…")
        .accessibilityLabel("Open with another app")
    }
    private var apps: [URL] {
        let all = NSWorkspace.shared.urlsForApplications(toOpen: url)
        let preferred = ["TextEdit", "Obsidian", "Typora", "MarkEdit", "Visual Studio Code", "Cursor", "BBEdit", "Sublime Text"]
        let rank = { (app: URL) in preferred.firstIndex(of: app.deletingPathExtension().lastPathComponent) ?? preferred.count }
        var seen = Set<String>()
        return all.filter { seen.insert($0.lastPathComponent).inserted }
            .sorted { (rank($0), $0.lastPathComponent) < (rank($1), $1.lastPathComponent) }
    }
    private func icon(_ app: URL) -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: app.path)
        image.size = NSSize(width: 16, height: 16)
        return image
    }
}

// Renders Nosy's own markdown: title, metadata bullets, headings, paragraphs.
private struct TranscriptText: View {
    let markdown: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .title(let text): Text(text).font(Theme.display(24, .bold)).foregroundStyle(Theme.ink)
                case .meta(let items):
                    HStack(spacing: 8) {
                        ForEach(items, id: \.self) { item in
                            Text(item).font(Theme.text(11.5, .semibold)).foregroundStyle(Theme.muted)
                                .padding(.horizontal, 9).frame(height: 22).background(Theme.surface, in: Capsule())
                        }
                    }
                case .heading(let text):
                    Text(text.uppercased()).font(Theme.label).kerning(0.8).foregroundStyle(Theme.muted).padding(.top, 6)
                        .accessibilityAddTraits(.isHeader)
                case .paragraph(let text):
                    Text((try? AttributedString(markdown: text)) ?? AttributedString(text))
                        .font(Theme.text(15)).foregroundStyle(Theme.ink).lineSpacing(5)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private enum Block { case title(String), meta([String]), heading(String), paragraph(String) }
    private var blocks: [Block] {
        var result: [Block] = []
        for chunk in markdown.components(separatedBy: "\n\n") {
            let lines = chunk.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard let first = lines.first else { continue }
            if first.hasPrefix("# ") { result.append(.title(String(first.dropFirst(2)))) }
            else if first.hasPrefix("## ") { result.append(.heading(String(first.dropFirst(3)))) }
            else if lines.allSatisfy({ $0.hasPrefix("- ") }) { result.append(.meta(lines.map { String($0.dropFirst(2)) })) }
            else { result.append(.paragraph(lines.joined(separator: " "))) }
        }
        return result
    }
}

// List rows: tint on hover, accent fill when selected, slight press.
struct RowButtonStyle: ButtonStyle {
    var selected: Bool
    func makeBody(configuration: Configuration) -> some View { RowBody(configuration: configuration, selected: selected) }
    private struct RowBody: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovering = false
        var body: some View {
            configuration.label
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .leading) {
                    Capsule().fill(Theme.accent).frame(width: 3, height: selected ? 18 : 0).offset(x: 1)
                }
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
                .contentShape(Rectangle())
                .onHover { inside in withAnimation(Motion.hover) { hovering = inside } }
                .animation(Motion.press, value: configuration.isPressed)
                .animation(Motion.state(reduceMotion), value: selected)
        }
        private var fill: Color {
            selected ? Theme.accent.opacity(0.14) : (hovering ? Theme.surface : .clear)
        }
    }
}
