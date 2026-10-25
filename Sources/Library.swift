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

// The tree's open folders. A search opens every match without changing the saved choice,
// and a folder toggled during a search stays that way until the search changes.
struct TranscriptFolders: Equatable {
    static let storageKey = "transcriptFoldersOpen"
    private(set) var open: Set<String>
    private var closedWhileSearching: Set<String> = []

    init(open: Set<String> = []) { self.open = open }

    func isOpen(_ folder: String, searching: Bool) -> Bool {
        searching ? !closedWhileSearching.contains(folder) : open.contains(folder)
    }
    mutating func toggle(_ folder: String, searching: Bool) {
        if searching {
            if !closedWhileSearching.insert(folder).inserted { closedWhileSearching.remove(folder) }
        } else if !open.insert(folder).inserted {
            open.remove(folder)
        }
    }
    mutating func reveal(_ folder: String) { open.insert(folder) }
    mutating func remove(_ folder: String) {
        open.remove(folder)
        closedWhileSearching.remove(folder)
    }
    mutating func endSearch() { closedWhileSearching = [] }
}

// Reader rules. The files on disk keep their Markdown; only the display changes.
enum TranscriptDisplay {
    // Core writes this exact body for a recording with no speech.
    static func isNoSpeech(_ paragraph: String) -> Bool {
        paragraph.trimmingCharacters(in: .whitespacesAndNewlines) == "_No speech detected._"
    }
}

// Reads the transcripts folder (one subfolder per lecture, one .md per session) once per
// reload and keeps the text in memory, so search never touches the disk while typing.
@MainActor
final class TranscriptLibrary: ObservableObject {
    @Published private(set) var items: [TranscriptItem] = []
    @Published private(set) var unfinished: [SessionRecord] = []
    @Published private(set) var selection: URL?
    @Published private(set) var selectedFolder: String?
    // The folder row the keyboard acts on: Delete and ⌘Delete move it to the Trash. Choosing a transcript clears it.
    @Published private(set) var focusedFolder: String?
    @Published var query = "" { didSet { folders.endSearch(); keepSelectionVisible() } }
    // Open folders in the tree. They are saved to `store` only when the Transcripts window restores them.
    @Published private(set) var folders = TranscriptFolders() {
        didSet {
            guard oldValue.open != folders.open else { return }
            store?.set(folders.open.sorted(), forKey: TranscriptFolders.storageKey)
        }
    }
    private var store: UserDefaults?
    @Published private(set) var editing = false
    @Published var draft = ""
    private var editingItem: TranscriptItem?
    private var editingPaths: AppPaths?
    private var loadedRoot: URL?
    var didChange: ((URL, URL?) -> Void)?
    enum DraftChoice { case save, discard, cancel }
    var chooseDraftAction: () -> DraftChoice = {
        let alert = NSAlert()
        alert.messageText = "Save your transcript changes?"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertSecondButtonReturn: return .discard
        default: return .cancel
        }
    }

    func beginEditing(paths: AppPaths) {
        guard let selected else { return }
        editingItem = selected
        editingPaths = paths
        draft = selected.text
        editing = true
    }
    func cancelEdit() { editing = false; editingItem = nil; editingPaths = nil }
    @discardableResult func saveDraft() -> Bool {
        guard let item = editingItem, let paths = editingPaths,
              save(draft, to: item.url, paths: paths, expectedText: item.text) else { return false }
        cancelEdit()
        return true
    }
    @discardableResult func finishEditing() -> Bool {
        guard editing else { return true }
        guard draft != editingItem?.text else { cancelEdit(); return true }
        switch chooseDraftAction() {
        case .save: return saveDraft()
        case .discard: cancelEdit(); return true
        case .cancel: return false
        }
    }
    @discardableResult func select(_ url: URL?) -> Bool {
        let target = url.map { requested in
            items.first { $0.url.resolvingSymlinksInPath() == requested.resolvingSymlinksInPath() }?.url ?? requested
        }
        guard selection != target else { focusedFolder = nil; return true }
        guard finishEditing() else { return false }
        focusedFolder = nil
        setSelection(target)
        return true
    }
    func open(_ url: URL, paths: AppPaths) {
        guard (selection == url && loadedRoot == paths.transcripts) || finishEditing() else { return }
        query = ""
        reload(paths: paths)
        _ = select(url)
    }

    func reload(paths: AppPaths) {
        if loadedRoot != paths.transcripts, !finishEditing() { return }
        loadedRoot = paths.transcripts
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .creationDateKey]
        let root = paths.transcripts
        let lectures = (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: keys, options: [])) ?? []
        // Transcripts Nosy wrote stay listed even if their header was edited away.
        let written = Set(Core.records(in: paths).compactMap(\.transcriptPath).map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        items = lectures.flatMap { folder -> [TranscriptItem] in
            guard Core.isContained(folder, in: root),
                  (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return [] }
            let files = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [])) ?? []
            let markdown = files.filter { $0.pathExtension.lowercased() == "md" }
            // A summary sits next to its transcript; it is read from the transcript, not listed.
            let names = Set(markdown.map(\.lastPathComponent))
            return markdown.filter { Core.isContained($0, in: root)
                && (written.contains($0.standardizedFileURL.path) || !SummaryFiles.isSummary($0, siblings: names)) }.compactMap { url in
                // Only files Nosy wrote: never the owner's other notes that share the folder.
                guard let text = try? String(contentsOf: url, encoding: .utf8),
                      Core.isTranscript(text) || written.contains(url.standardizedFileURL.path) else { return nil }
                // Creation date stays put when a transcript is edited elsewhere, so the order doesn't jump.
                return TranscriptItem(url: url, lecture: folder.lastPathComponent, session: url.deletingPathExtension().lastPathComponent,
                                      recorded: (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast,
                                      text: text)
            }
        }.sorted { $0.recorded > $1.recorded }
        if let focusedFolder, !items.contains(where: { $0.lecture == focusedFolder }) { self.focusedFolder = nil }
        unfinished = Core.unfinished(paths: paths)
        keepSelectionVisible()
    }
    var selected: TranscriptItem? { editing ? editingItem : items.first { $0.url == selection } }
    var importTargetLecture: String? { selectedFolder ?? selected?.lecture }
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
    var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    func isOpen(_ lecture: String) -> Bool { folders.isOpen(lecture, searching: searching) }
    func selectFolder(_ lecture: String) { selectedFolder = lecture }
    func focusFolder(_ lecture: String) { focusedFolder = lecture }
    // Rows on screen, top to bottom: a closed folder hides its sessions.
    var visibleRows: [TranscriptItem] { grouped.filter { isOpen($0.lecture) }.flatMap(\.items) }
    func toggleFolder(_ lecture: String) { folders.toggle(lecture, searching: searching) }
    func removeFolderState(_ lecture: String) { folders.remove(lecture) }
    // Previews show the tree with every folder closed.
    func collapseFolders() { folders = TranscriptFolders() }
    // Restores the saved open folders. Pass nil to keep them for this window only.
    func restoreFolders(from defaults: UserDefaults?) {
        store = defaults
        folders = TranscriptFolders(open: Set(defaults?.stringArray(forKey: TranscriptFolders.storageKey) ?? []))
    }

    // Searching never leaves a hidden transcript open (where Trash would still act on it).
    private func keepSelectionVisible() {
        guard !editing else { return }
        if let selection, ordered.contains(where: { $0.url == selection }) { return }
        setSelection(filtered.first?.url)
    }
    // Selecting a transcript opens its folder, so the one in the reader is always in the tree.
    private func setSelection(_ url: URL?) {
        selection = url
        guard let url, let lecture = items.first(where: { $0.url == url })?.lecture else {
            selectedFolder = nil
            return
        }
        selectedFolder = lecture
        guard !searching else { return }
        folders.reveal(lecture)
    }
    func move(_ step: Int) {
        let list = visibleRows
        guard !list.isEmpty else { return }
        let index = list.firstIndex { $0.url == selection } ?? (step > 0 ? -1 : list.count)
        _ = select(list[min(list.count - 1, max(0, index + step))].url)
    }

    // Moves a transcript to the Trash (recoverable) and selects its neighbour.
    func trash(_ url: URL, paths: AppPaths) {
        guard items.contains(where: { $0.url == url }), Core.isContained(url, in: paths.transcripts), finishEditing() else { return }
        let list = ordered
        let index = list.firstIndex(where: { $0.url == url })
        do {
            if let summary = SummaryFiles.existing(for: url) { try FileManager.default.trashItem(at: summary, resultingItemURL: nil) }
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Couldn't move this transcript to the Trash"
            alert.runModal()
            return
        }
        didChange?(url, nil)
        let remaining = list.filter { $0.url != url }
        if selection == url {
            setSelection(index.flatMap { remaining.indices.contains($0) ? remaining[$0].url : remaining.last?.url })
        }
        reload(paths: paths)
    }

    // A folder that the shared Trash path just moved: drop it from the tree and keep the reader on a nearby session.
    func folderRemoved(_ lecture: String, paths: AppPaths) {
        guard loadedRoot == paths.transcripts else { return }
        let list = ordered
        let oldSelection = selection
        let selectionIndex = list.firstIndex { $0.url == oldSelection }
        let removedURLs = Set(items.filter { $0.lecture == lecture }.map(\.url))
        removeFolderState(lecture)
        let selectedFolderWasRemoved = selectedFolder == lecture
        if selectedFolderWasRemoved { selectedFolder = nil }
        reload(paths: paths)
        if let oldSelection, removedURLs.contains(oldSelection) {
            let remaining = list.filter { !removedURLs.contains($0.url) }
            let next = selectionIndex.flatMap { index in
                remaining.indices.contains(index) ? remaining[index].url : remaining.last?.url
            } ?? remaining.first?.url
            setSelection(next)
        } else if selectedFolderWasRemoved, let selection {
            setSelection(selection)
        }
    }

    func rename(_ item: TranscriptItem, paths: AppPaths) {
        guard finishEditing() else { return }
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
            try rename(item, to: name, paths: paths)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
    func rename(_ item: TranscriptItem, to name: String, paths: AppPaths) throws {
        guard items.contains(item), Core.isContained(item.url, in: paths.transcripts) else {
            throw LectureError.message("This transcript is outside the selected library.")
        }
        let target = Core.uniqueTranscript(in: item.url.deletingLastPathComponent(), session: try Core.sanitize(name))
        let record = Core.record(forTranscript: item.url, paths: paths)
        let summary = SummaryFiles.existing(for: item.url)
        try FileManager.default.moveItem(at: item.url, to: target)
        do {
            if let summary { try FileManager.default.moveItem(at: summary, to: SummaryFiles.url(for: target)) }
            if var record { record.transcriptPath = target.path; try record.save(in: paths) }
        } catch {
            if let summary, FileManager.default.fileExists(atPath: SummaryFiles.url(for: target).path) {
                try? FileManager.default.moveItem(at: SummaryFiles.url(for: target), to: summary)
            }
            try? FileManager.default.moveItem(at: target, to: item.url)
            throw error
        }
        didChange?(item.url, target)
        reload(paths: paths)
        setSelection(target)
    }
    @discardableResult func save(_ text: String, to url: URL, paths: AppPaths, expectedText: String? = nil) -> Bool {
        do {
            guard Core.isContained(url, in: paths.transcripts) else { throw LectureError.message("This transcript is outside the selected library.") }
            guard let expected = expectedText ?? items.first(where: { $0.url == url })?.text else {
                throw LectureError.message("Reload this transcript before editing it.")
            }
            try Core.saveTranscriptEdits(text, to: url, expectedText: expected)
            didChange?(url, url)
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
    @ObservedObject private var summaries: SummaryCenter
    @StateObject private var library = TranscriptLibrary()
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focus: Focus?
    @State private var dropping = false
    @State private var copied = false
    // Transcript | Summary in the reader, and the summary text for the selected transcript.
    @State private var showSummary = false
    @State private var summaryText: String?
    @State private var requestedSummary: URL?
    @State private var browsingRoot: URL?
    private var libraryPaths: AppPaths { model.paths.browsingLibrary(at: browsingRoot ?? model.paths.transcripts) }
    var previewQuery: String?
    var previewCollapsed: Bool
    var previewSummary: Bool
    var previewDropping: Bool
    var previewHoveredFolder: String?
    var previewFocusedFolder: String?
    private var editing: Bool { library.editing }
    private var fold: Animation { reduceMotion ? .easeOut(duration: 0.12) : .easeInOut(duration: 0.24) }
    enum Focus { case search, list }

    init(model: AppModel, previewQuery: String? = nil, previewCollapsed: Bool = false, previewSummary: Bool = false,
         previewDropping: Bool = false, previewHoveredFolder: String? = nil, previewFocusedFolder: String? = nil) {
        self.model = model
        _summaries = ObservedObject(wrappedValue: model.summaries)
        self.previewQuery = previewQuery
        self.previewCollapsed = previewCollapsed
        self.previewSummary = previewSummary
        self.previewDropping = previewDropping
        self.previewHoveredFolder = previewHoveredFolder
        self.previewFocusedFolder = previewFocusedFolder
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Theme.line).frame(width: 1)
            reader
        }
        .frame(minWidth: 720, minHeight: 460)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WindowBackdrop())
        .safeAreaPadding(.top, 20)
        .tint(Theme.accentText)
        .onExitCommand(perform: closeAndShowMain)
        .onAppear {
            model.openWindow = openWindow
            if previewDropping { dropping = true }
            library.didChange = { old, new in model.transcriptChanged(from: old, to: new) }
            model.finishLibraryEditing = { [weak library = library] in library?.finishEditing() ?? true }
            model.onFolderTrashed = { [weak library = library] lecture, trashed in library?.folderRemoved(lecture, paths: trashed) }
            library.restoreFolders(from: Snapshot.isRunning ? nil : .standard)
            reload()
            applyFocus()
            if previewCollapsed { library.collapseFolders() }
            if let previewFocusedFolder { library.focusFolder(previewFocusedFolder) }
            if let previewQuery { library.query = previewQuery }
            loadSummary()
            if previewSummary, summaryText != nil { showSummary = true }
        }
        .onChange(of: library.selection) { loadSummary(); showSummary = previewSummary && summaryText != nil }
        .onReceive(model.summaries.$revision.dropFirst()) { _ in
            loadSummary()
            if let requestedSummary, requestedSummary == library.selection, summaryText != nil {
                showSummary = true
                self.requestedSummary = nil
            }
        }
        .onChange(of: model.paths.transcripts) { browsingRoot = nil; reload() }
        .onChange(of: model.current?.transcriptPath) { reload() }
        .onChange(of: model.active?.id) { reload() }
        .onChange(of: model.libraryFocus) { reload(); applyFocus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in reload() }
        .tipContainerBounds()
        .dropDestination(for: URL.self) { urls, _ in
            guard !model.busy else { return false }
            model.importRecordings(urls, targetLecture: library.importTargetLecture)
            return true
        } isTargeted: { dropping = $0 && !model.busy }
        .overlay {
            if dropping { AudioDropOverlay().padding(10).allowsHitTesting(false) }
        }
    }
    private func reload() { library.reload(paths: libraryPaths); loadSummary() }
    private func loadSummary() {
        summaryText = library.selection.flatMap(SummaryFiles.existing(for:)).flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        if summaryText == nil { showSummary = false }
    }
    private var showingSummary: Bool { showSummary && summaryText != nil && !editing }
    private func applyFocus() {
        guard let url = model.libraryFocus else { return }
        guard library.finishEditing() else { model.libraryFocus = nil; return }
        if let root = model.libraryLocations.first(where: { Core.isContained(url, in: $0) }) {
            browsingRoot = root
        }
        library.open(url, paths: libraryPaths)
        model.libraryFocus = nil
    }
    private func closeAndShowMain() {
        guard library.finishEditing() else { return }
        dismiss()
        openWindow(id: "main")
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first(where: { $0.title == "Nosy" })?.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button(action: closeAndShowMain) {
                HStack(spacing: 7) {
                    Image(systemName: "house.fill").font(.system(size: 12, weight: .semibold))
                    Text("Nosy")
                }
            }
            .buttonStyle(PillButtonStyle(kind: .quiet, height: 32, fullWidth: false))
            .keyboardShortcut("w", modifiers: .command)
            .accessibilityLabel("Close Transcripts and return to Nosy")

            HStack(spacing: 10) {
                NosyMark(size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Transcripts").font(Theme.display(18, .bold)).foregroundStyle(Theme.ink)
                    Text("\(library.items.count) saved").font(Theme.text(10)).foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4).padding(.top, 6)
            if model.libraryLocations.count > 1 { libraryLocationMenu }
            Button {
                model.importRecordingPanel(targetLecture: library.importTargetLecture)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "square.and.arrow.down").font(.system(size: 12, weight: .semibold))
                    Text("Import audio")
                }
            }
            .buttonStyle(PillButtonStyle(kind: .quiet, height: 32, fullWidth: false))
            .tip("Transcribe an audio or video file")
            .accessibilityLabel("Import audio")
            .disabled(model.busy)
            importActivity
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
                    VStack(alignment: .leading, spacing: 8) {
                        if library.unfinished.contains(where: { !model.isLive($0.id) }), library.query.isEmpty { unfinishedSection }
                        ForEach(library.grouped, id: \.lecture) { group in
                            folderGroup(group.lecture, group.items)
                        }
                        if library.grouped.isEmpty {
                            Text(library.query.isEmpty ? "No transcripts yet.\nRecord a session in a folder and it shows up here." : "Nothing matches “\(library.query)”.")
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
                // Delete and ⌘Delete trash the focused folder, with the same confirmation as its trash button.
                .onKeyPress(.delete) {
                    if let lecture = library.focusedFolder { confirmTrashFolder(lecture) }
                    return .handled
                }
                .onChange(of: library.selection) { _, url in
                    if let url { withAnimation(Motion.hover) { proxy.scrollTo(url) } }
                }
            }
        }
        .padding(14)
        .disabled(editing)
        .opacity(editing ? 0.5 : 1)
        .frame(width: 250)
        .background(Theme.surface.opacity(0.45))
    }
    private var libraryLocationMenu: some View {
        Menu {
            ForEach(model.libraryLocations, id: \.path) { root in
                Button {
                    guard library.finishEditing() else { return }
                    browsingRoot = root
                    reload()
                } label: {
                    let label = root.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
                    if root == libraryPaths.transcripts { Label(label, systemImage: "checkmark") }
                    else { Text(label) }
                }
            }
        } label: {
            HStack {
                Text(libraryPaths.transcripts.lastPathComponent).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down").font(.system(size: 9))
                    .accessibilityHidden(true)
            }.font(Theme.text(11.5)).foregroundStyle(Theme.ink)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Transcript library").accessibilityValue(libraryPaths.transcripts.path)
        }
        .menuStyle(.button).buttonStyle(PillButtonStyle(kind: .quiet, height: 28, fullWidth: true)).menuIndicator(.hidden)
        .accessibilityLabel("Transcript library").accessibilityValue(libraryPaths.transcripts.path)
        .tip("Browse current and previous libraries")
    }

    @ViewBuilder private var importActivity: some View {
        if model.importsInProgress > 0 {
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text("Importing audio · \(model.importsInProgress) left")
                    .font(Theme.text(11)).foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 4)
            .accessibilityLabel("Importing audio, \(model.importsInProgress) left")
        } else if let active = model.active {
            HStack(spacing: 7) {
                ProgressView(value: model.transcriptionProgress).controlSize(.small).frame(width: 42)
                Text(model.transcriptionPauseReason.map { "Paused · \($0)" }
                     ?? "Transcribing audio · \(Int((model.transcriptionProgress * 100).rounded()))%")
                    .font(Theme.text(11)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            .padding(.horizontal, 4)
            .accessibilityLabel("Transcribing \(active.lecture) \(active.session)")
        } else if !model.queue.isEmpty {
            Text("Audio queued for transcription")
                .font(Theme.text(11)).foregroundStyle(Theme.muted).padding(.horizontal, 4)
        } else if let message = model.errorMessage {
            Text(message).font(Theme.text(11)).foregroundStyle(Theme.coral).lineLimit(2)
                .padding(.horizontal, 4)
        }
    }

    // A folder row, with its sessions nested beneath it when open.
    @ViewBuilder private func folderGroup(_ lecture: String, _ items: [TranscriptItem]) -> some View {
        let open = library.isOpen(lecture)
        VStack(alignment: .leading, spacing: 2) {
            TranscriptFolderRow(lecture: lecture, count: items.count, open: open,
                selected: (library.focusedFolder ?? library.selectedFolder) == lecture,
                previewHovered: previewHoveredFolder == lecture,
                trashLocked: items.contains(where: { summaries.isBusy($0.url) }),
                toggle: {
                    library.selectFolder(lecture)
                    library.focusFolder(lecture)
                    focus = .list
                    withAnimation(fold) { library.toggleFolder(lecture) }
                }, trash: { confirmTrashFolder(lecture) })
            if open {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(items) { item in
                        TranscriptSidebarRow(item: item, selected: library.selection == item.url,
                            open: { library.select(item.url); focus = .list },
                            reveal: { NSWorkspace.shared.activateFileViewerSelecting([item.url]) },
                            rename: { library.rename(item, paths: libraryPaths) },
                            trash: { library.trash(item.url, paths: libraryPaths) }, mutationsLocked: summaries.isBusy(item.url))
                            .id(item.url)
                    }
                }
                .padding(.leading, 22)
                .background(alignment: .leading) {
                    Rectangle().fill(Theme.line).frame(width: 1).padding(.leading, 16)
                }
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func confirmTrashFolder(_ lecture: String) {
        guard !library.items.contains(where: { $0.lecture == lecture && summaries.isBusy($0.url) }) else { return }
        guard model.finishLibraryEditing?() ?? true, LectureFolderTrash.confirm(lecture) else { return }
        if model.trashLecture(lecture, paths: libraryPaths) { loadSummary() }
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
                        Text(model.isQueued(record.id) ? (model.transcriptionPauseReason.map { "Paused. \($0)" } ?? (model.active?.id == record.id ? "Transcribing…" : "Queued")) : "\(Core.minutes(Core.audioDuration(id: record.id, paths: model.paths))) min · not transcribed")
                            .font(Theme.text(11)).monospacedDigit().foregroundStyle(Theme.muted)
                    }
                    Spacer(minLength: 0)
                    Button { model.retry(record) } label: { Image(systemName: "text.badge.plus") }
                        .buttonStyle(IconButtonStyle(size: 26))
                        .tip("Transcribe audio").accessibilityLabel("Transcribe \(record.lecture) \(record.session)")
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
                if !editing {
                    SummaryBar(transcript: item.url, summaries: model.summaries, hasSummary: summaryText != nil,
                               showSummary: $showSummary) { requestedSummary = item.url }
                    Rectangle().fill(Theme.line).frame(height: 1)
                }
                if editing {
                    TextEditor(text: $library.draft)
                        .font(Theme.text(15))
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 22).padding(.vertical, 16)
                        .accessibilityLabel("Transcript text")
                } else if showingSummary, let summaryText {
                    ScrollView {
                        SummaryText(markdown: summaryText)
                            .padding(.horizontal, 30).padding(.vertical, 24)
                            .frame(maxWidth: 640, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .scrollIndicators(.automatic)
                    .textSelection(.enabled)
                } else {
                    ScrollView {
                        TranscriptText(markdown: item.text, canCorrect: !summaries.isBusy(item.url)) { range, replacement in
                            guard !summaries.isBusy(item.url) else { return }
                            let folder = item.url.deletingLastPathComponent()
                            do {
                                try Vocabulary.remember(replacement, folder: folder)
                                let corrected = (item.text as NSString).replacingCharacters(in: range, with: replacement)
                                _ = library.save(corrected, to: item.url, paths: libraryPaths, expectedText: item.text)
                            } catch { NSAlert(error: error).runModal() }
                        }
                        .padding(.horizontal, 30).padding(.vertical, 24)
                        .frame(maxWidth: 640, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .scrollIndicators(.automatic)
                    .textSelection(.enabled)
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
                Text(item.session).font(Theme.display(20, .bold)).foregroundStyle(Theme.ink).lineLimit(1)
                Text(item.lecture).font(Theme.text(12, .medium)).foregroundStyle(Theme.muted).lineLimit(1)
                Text(readerMetadata(item)).font(Theme.text(11.5)).foregroundStyle(Theme.muted).lineLimit(1).monospacedDigit()
            }
            Spacer()
            if editing {
                Button("Cancel") { library.cancelEdit() }
                    .buttonStyle(PillButtonStyle(kind: .quiet, height: 30, fullWidth: false))
                    .tip("Discard changes")
                    .keyboardShortcut(.cancelAction)
                Button("Save") { library.saveDraft() }
                    .buttonStyle(PillButtonStyle(kind: .primary, height: 30, fullWidth: false))
                    .tip("Save changes")
                    .keyboardShortcut("s", modifiers: .command)
            } else {
                Button { showSummary = false; library.beginEditing(paths: libraryPaths) } label: { Image(systemName: "pencil") }
                    .buttonStyle(IconButtonStyle(size: 32)).keyboardShortcut("e", modifiers: .command)
                    .tip("Edit").accessibilityLabel("Edit transcript")
                    .disabled(summaries.isBusy(item.url))
                Button { copy(showingSummary ? summaryText ?? item.text : item.text) } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc").contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(IconButtonStyle(size: 32, active: copied))
                .tip(copied ? "Copied" : "Copy").accessibilityLabel(showingSummary ? "Copy summary" : "Copy transcript")
                ExportMenu(item: item)
                Button { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } label: { Image(systemName: "folder") }
                    .buttonStyle(IconButtonStyle(size: 32)).tip("Show in Finder").accessibilityLabel("Show in Finder")
                OpenWithMenu(url: item.url)
                Button { library.trash(item.url, paths: libraryPaths) } label: { Image(systemName: "trash") }
                    .buttonStyle(IconButtonStyle(size: 32, destructive: true))
                    .keyboardShortcut(focus == .list && library.focusedFolder == nil ? KeyboardShortcut(.delete, modifiers: .command) : nil)
                    .tip("Move to Trash")
                    .accessibilityLabel("Move transcript to Trash")
                    .disabled(summaries.isBusy(item.url))
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 14)
    }

    private func readerMetadata(_ item: TranscriptItem) -> String {
        let record = Core.record(forTranscript: item.url, paths: model.paths)
        let start = record?.startedAt ?? item.recorded
        let date = Core.dateString(start, format: "MMM d, yyyy")
        let time = Core.dateString(start, format: "HH:mm")
        let duration: TimeInterval
        if let record, Core.audioDuration(id: record.id, paths: model.paths) > 0 {
            duration = Core.audioDuration(id: record.id, paths: model.paths)
        } else if let line = item.text.components(separatedBy: .newlines).first(where: { $0.hasPrefix("- Length:") }),
                  let minutes = line.dropFirst("- Length:".count).trimmingCharacters(in: .whitespaces).split(separator: " ").first.flatMap({ Double($0) }) {
            duration = minutes * 60
        } else {
            duration = 60
        }
        return "\(date) · \(time) · \(Core.minutes(duration)) min"
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        withAnimation(Motion.press) { copied = true }
        Task { try? await Task.sleep(for: .seconds(1.4)); withAnimation(Motion.hover) { copied = false } }
    }
}

// A folder in the Transcripts tree: the big row. Its chevron turns as it opens.
private struct TranscriptFolderRow: View {
    let lecture: String
    let count: Int
    let open: Bool
    let selected: Bool
    let previewHovered: Bool
    let trashLocked: Bool
    let toggle: () -> Void
    let trash: () -> Void
    @State private var hovering = false
    private var showsTrash: Bool { hovering || previewHovered }

    var body: some View {
        HStack(spacing: 2) {
            Button(action: toggle) {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.muted)
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .frame(width: 12)
                    Image(systemName: open ? "folder.fill" : "folder")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Theme.navy)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 18)
                    Text(lecture)
                        .font(Theme.text(15, .semibold)).foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text("\(count)")
                        .font(Theme.text(11, .semibold)).monospacedDigit().foregroundStyle(Theme.muted)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Theme.surface, in: Capsule())
                        .overlay(Capsule().strokeBorder(Theme.line, lineWidth: 1))
                }
                .padding(.horizontal, 10).padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .frame(maxWidth: .infinity)
            .background(selected ? Theme.accent.opacity(0.09) : .clear,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .buttonStyle(FolderRowStyle())
            .accessibilityLabel("\(lecture), \(count) \(count == 1 ? "session" : "sessions")")
            .accessibilityValue(open ? "Expanded" : "Collapsed")

            Button(action: trash) { Image(systemName: "trash") }
                .buttonStyle(IconButtonStyle(size: 23, destructive: true))
                .tip("Delete folder")
                .accessibilityLabel("Delete \(lecture)")
                .opacity(showsTrash ? 1 : 0)
                .disabled(!showsTrash || trashLocked)
                .animation(Motion.hover, value: showsTrash)
        }
        .padding(.trailing, 4)
        .frame(maxWidth: .infinity)
        .onHover { inside in withAnimation(Motion.hover) { hovering = inside } }
    }
}

// Folder rows tint on hover and ease down when pressed.
private struct FolderRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { FolderRowBody(configuration: configuration) }
    private struct FolderRowBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovering = false
        var body: some View {
            configuration.label
                .background(hovering ? Theme.surface : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
                .onHover { inside in withAnimation(Motion.hover) { hovering = inside } }
                .animation(Motion.press, value: configuration.isPressed)
        }
    }
}

// Session rows sit under their folder: small text, a short date, and the accent bar when selected.
private struct SessionRowStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        SessionRowBody(configuration: configuration, selected: selected)
    }
    private struct SessionRowBody: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovering = false
        var body: some View {
            configuration.label
                .background(fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(alignment: .leading) {
                    Capsule().fill(Theme.accent).frame(width: 3, height: selected ? 14 : 0)
                }
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
                .contentShape(Rectangle())
                .onHover { inside in withAnimation(Motion.hover) { hovering = inside } }
                .animation(Motion.press, value: configuration.isPressed)
                .animation(Motion.state(reduceMotion), value: selected)
        }
        private var fill: Color {
            selected ? Theme.accent.opacity(0.12) : (hovering ? Theme.surface : .clear)
        }
    }
}

private struct TranscriptSidebarRow: View {
    let item: TranscriptItem
    let selected: Bool
    let open: () -> Void
    let reveal: () -> Void
    let rename: () -> Void
    let trash: () -> Void
    var mutationsLocked = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 2) {
            Button(action: open) {
                HStack(spacing: 6) {
                    Text(item.session)
                        .font(Theme.text(11.5, .semibold)).monospacedDigit().foregroundStyle(Theme.ink).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(item.recorded.formatted(.dateTime.month(.abbreviated).day()))
                        .font(Theme.text(10)).monospacedDigit().foregroundStyle(Theme.muted).lineLimit(1)
                }
                .padding(.leading, 8).padding(.trailing, 6).padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(SessionRowStyle(selected: selected))
            .accessibilityLabel("\(item.lecture), \(item.session)")
            .accessibilityAddTraits(selected ? .isSelected : [])

            Button(action: reveal) {
                Image(systemName: "folder")
            }
            .buttonStyle(IconButtonStyle(size: 24, active: selected))
            .opacity(hovering || selected ? 1 : 0)
            .accessibilityLabel("Show \(item.session) in Finder")
            .tip("Show in Finder", edge: .trailing)
        }
        // Inset from the sidebar's right edge so the round button is never clipped.
        .padding(.trailing, 6)
        .frame(maxWidth: .infinity)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Rename…", action: rename)
                .disabled(mutationsLocked)
            Button("Show in Finder", action: reveal)
            Divider()
            Button("Move to Trash", role: .destructive, action: trash)
                .disabled(mutationsLocked)
        }
    }
}

// A compact in-window recent list; opening an item keeps transcript reading and audio playback
// in the main window while the full library remains available from the toolbar.
struct RecentView: View {
    @ObservedObject var model: AppModel
    @Binding var selection: URL?
    @Binding var showingAudio: Bool
    var compact = false
    var onHome: () -> Void = {}
    @StateObject private var library = TranscriptLibrary()
    @Environment(\.openWindow) private var openWindow

    init(model: AppModel, selection: Binding<URL?>, showingAudio: Binding<Bool>,
         compact: Bool = false, onHome: @escaping () -> Void = {}) {
        self.model = model
        _selection = selection
        _showingAudio = showingAudio
        self.compact = compact
        self.onHome = onHome
    }

    private var selected: TranscriptItem? {
        guard let selection else { return nil }
        let path = selection.standardizedFileURL.path
        return library.items.first { $0.url.standardizedFileURL.path == path }
    }
    private var selectedAudio: URL? {
        guard let selected else { return nil }
        return Core.record(forTranscript: selected.url, paths: model.paths)
            .flatMap { AudioFiles.playable(id: $0.id, paths: model.paths) }
    }

    var body: some View {
        Group {
            if let selected {
                detail(selected)
            } else if compact {
                compactList
            } else {
                compactList
            }
        }
        .onAppear { reload() }
        .onChange(of: model.paths.transcripts) { reload() }
        .onChange(of: model.current?.transcriptPath) { reload() }
        .onChange(of: model.active?.id) { reload() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in reload() }
    }

    private var compactList: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Recent").font(Theme.label).foregroundStyle(Theme.muted)
                Spacer()
                Button("See all") { openWindow(id: "library") }
                    .buttonStyle(LinkButtonStyle(tint: Theme.navy))
                    .tip("Open transcripts")
            }
            if library.items.isEmpty {
                Text("No saved sessions yet")
                    .font(Theme.text(11)).foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading).frame(height: 22)
            } else {
                VStack(spacing: 2) {
                    ForEach(Array(library.items.prefix(3))) { item in
                        HStack(spacing: 4) {
                            Button {
                                selection = item.url
                                showingAudio = false
                            } label: {
                                Text("\(item.session) · \(item.recorded.formatted(date: .abbreviated, time: .omitted))")
                                    .font(Theme.text(11, .medium)).monospacedDigit().lineLimit(1).truncationMode(.middle)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(RowButtonStyle(selected: false))
                            .tip("Open transcript")
                            .accessibilityLabel("Open \(item.lecture), \(item.session)")
                            Button { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } label: {
                                Image(systemName: "folder")
                            }
                            .buttonStyle(IconButtonStyle(size: 24))
                            .tip("Show in Finder")
                            .accessibilityLabel("Show \(item.session) in Finder")
                        }
                        .frame(height: 24)
                        .contextMenu {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                                .tip("Show in Finder")
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8).card()
    }

    private func detail(_ item: TranscriptItem) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Button { onHome() } label: {
                    Label("Home", systemImage: "house")
                }
                .buttonStyle(LinkButtonStyle(tint: Theme.navy))
                .tip("Back to ready")
                Spacer(minLength: 2)
                HStack(spacing: 2) {
                    Button { showingAudio = false } label: { Text("Transcript") }
                        .buttonStyle(RecentToggleStyle(selected: !showingAudio))
                        .tip("Read transcript")
                    Button { showingAudio = true } label: { Text("Audio") }
                        .buttonStyle(RecentToggleStyle(selected: showingAudio))
                        .disabled(selectedAudio == nil)
                        .tip(selectedAudio == nil ? "Audio unavailable" : "Play recording")
                }
                .padding(2).background(Theme.surface.opacity(0.68), in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.line, lineWidth: 1))
                Button { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } label: { Image(systemName: "folder") }
                    .buttonStyle(IconButtonStyle(size: 25))
                    .tip("Show in Finder")
                    .accessibilityLabel("Show in Finder")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.session).font(Theme.text(12, .semibold)).monospacedDigit().foregroundStyle(Theme.ink).lineLimit(1)
                Text(item.lecture).font(Theme.text(9)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Rectangle().fill(Theme.line).frame(height: 1)
            if showingAudio, let audio = selectedAudio {
                AudioStrip(url: audio).id(audio)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                ScrollView {
                    Text(item.text)
                        .font(Theme.text(10.5)).foregroundStyle(Theme.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .scrollIndicators(.visible)
            }
        }
    }

    private func reload() {
        library.reload(paths: model.paths)
        if let selection, !library.items.contains(where: { $0.url.standardizedFileURL.path == selection.standardizedFileURL.path }) {
            self.selection = nil
            showingAudio = false
        }
    }
}

private struct RecentToggleStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        RecentToggleBody(configuration: configuration, selected: selected)
    }
    private struct RecentToggleBody: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        @Environment(\.isEnabled) private var enabled
        @Environment(\.isFocused) private var focused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovering = false
        var body: some View {
            configuration.label
                .font(Theme.text(9, .medium))
                .foregroundStyle(selected ? Theme.ink : Theme.muted)
                .padding(.horizontal, 8).frame(height: 23)
                .background(selected ? Theme.raised : (hovering && enabled ? Theme.surface : .clear), in: Capsule())
                .overlay(Capsule().strokeBorder(selected ? Theme.line : .clear, lineWidth: 1))
                .scaleEffect(configuration.isPressed && enabled && !reduceMotion ? 0.97 : 1)
                .opacity(enabled ? 1 : 0.42)
                .overlay(Capsule().strokeBorder(focused ? Theme.accentText : .clear, lineWidth: 2).padding(-2))
                .contentShape(Capsule())
                .onHover { inside in withAnimation(Motion.hover) { hovering = inside } }
                .animation(Motion.press, value: configuration.isPressed)
        }
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
            .tip(player.playing ? "Pause audio" : "Play audio")
            .accessibilityLabel(player.playing ? "Pause audio" : "Play audio")
            Text(Core.timer(player.time)).font(Theme.text(11.5)).monospacedDigit().foregroundStyle(Theme.muted)
            Slider(value: Binding(get: { player.time }, set: { player.seek($0) }), in: 0...max(1, player.duration))
                .controlSize(.small)
                .tip("Seek audio")
                .accessibilityLabel("Playback position")
            Text(Core.timer(player.duration)).font(Theme.text(11.5)).monospacedDigit().foregroundStyle(Theme.muted)
            Menu {
                ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                    Button(rateLabel(rate)) { player.rate = Float(rate) }
                        .tip("Set playback speed")
                }
            } label: {
                Text(rateLabel(Double(player.rate))).font(Theme.text(12, .semibold))
            }
            .menuStyle(.button).font(Theme.text(10)).buttonStyle(PillButtonStyle(kind: .quiet, height: 26, fullWidth: false))
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
        .font(Theme.text(11))
        .buttonStyle(IconButtonStyle(size: 32))
        .menuIndicator(.hidden)
        .fixedSize()
        .tip("Share / Export")
        .accessibilityLabel("Export transcript")
    }
    private func savePanel(_ type: UTType) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = "\(item.lecture) · \(item.session)"
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
        let body = NSFont.systemFont(ofSize: 11.5)
        let title = NSFont.systemFont(ofSize: 20, weight: .semibold)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.paragraphSpacing = 9
        for line in lines(markdown) {
            let attributes: [NSAttributedString.Key: Any]
            switch line.kind {
            case .title: attributes = [.font: title, .foregroundColor: NSColor.black, .paragraphStyle: paragraph]
            case .meta: attributes = [.font: body, .foregroundColor: NSColor.darkGray, .paragraphStyle: paragraph]
            case .heading: attributes = [.font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.gray, .paragraphStyle: paragraph]
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
        .font(Theme.text(11))
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

// Renders transcript paragraphs and markers; the session title and details live in the header.
private struct TranscriptText: View {
    let markdown: String
    var canCorrect = true
    let correct: (NSRange, String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(visibleBlocks, id: \.offset) { block in
                switch block.content {
                case .title: EmptyView()
                case .meta(let items):
                    Text(items.map { "• \($0)" }.joined(separator: "\n"))
                        .font(Theme.text(15))
                        .lineSpacing(5)
                case .heading(let text):
                    Text(text).font(Theme.text(16, .semibold)).foregroundStyle(Theme.ink).padding(.top, 6)
                        .accessibilityAddTraits(.isHeader)
                case .marker(let timestamp, let label):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "bookmark.fill").font(.system(size: 10, weight: .semibold)).accessibilityHidden(true)
                        Text(timestamp).font(Theme.text(12)).monospacedDigit().foregroundStyle(Theme.accentText)
                        Text(label).font(Theme.text(15)).foregroundStyle(Theme.ink)
                    }
                    .foregroundStyle(Theme.accentText)
                    .padding(.vertical, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Marker at \(timestamp): \(label)")
                case .paragraph(let text) where TranscriptDisplay.isNoSpeech(text):
                    Text("No speech detected.")
                        .font(Theme.text(15)).italic()
                        .foregroundStyle(Theme.muted)
                case .paragraph(let text):
                    // Replace line breaks one-for-one so selection offsets still address the source.
                    FixWordView(markdown: text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " "), canCorrect: canCorrect) { range, replacement in
                        if let source = block.sourceRange(range) { correct(source, replacement) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var visibleBlocks: [TranscriptBlock] {
        TranscriptBlock.parse(markdown).filter { block in
            switch block.content {
            case .title: return false
            case .meta(let items):
                let metadataLabels = ["Date:", "Started:", "Length:"]
                return !items.allSatisfy { item in metadataLabels.contains(where: item.hasPrefix) }
            case .heading(let text): return text.caseInsensitiveCompare("Transcript") != .orderedSame
            case .marker, .paragraph: return true
            }
        }
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
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .leading) {
                    Capsule().fill(Theme.accent).frame(width: 3, height: selected ? 18 : 0).offset(x: 1)
                }
                .scaleEffect(configuration.isPressed && enabled && !reduceMotion ? 0.97 : 1)
                .opacity(enabled ? 1 : 0.42)
                .contentShape(Rectangle())
                .animation(Motion.press, value: configuration.isPressed)
                .animation(Motion.state(reduceMotion), value: selected)
        }
        private var fill: Color {
            selected ? Theme.accent.opacity(0.10) : .clear
        }
    }
}
