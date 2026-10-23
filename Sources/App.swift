import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }
    func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { $0.title == "Nosy" })?.makeKeyAndOrderFront(nil)
    }
    // Right-click the Dock icon while recording to pause or stop without opening the window.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let model = AppModel.shared
        guard model.recording else { return nil }
        let menu = NSMenu()
        menu.addItem(DockAction(model.paused ? "Resume Recording" : "Pause Recording") { model.togglePause() })
        menu.addItem(DockAction("Stop & Transcribe") { model.stop() })
        return menu
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = AppModel.shared
        // A dirty transcript draft must be saved or explicitly discarded before
        // either the immediate or background-work termination path.
        guard model.finishLibraryEditing?() ?? true else { return .terminateCancel }
        guard model.working else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = model.recording ? "A recording is still in progress. Quit anyway?" : "A recording is still transcribing. Quit anyway?"
        alert.informativeText = "Your audio is kept, so you can transcribe it the next time you open Nosy."
        // Cancel is the default so a stray Return never ends a lecture.
        let quit = alert.addButton(withTitle: "Quit")
        quit.keyEquivalent = ""
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\r"
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        Task {
            await model.prepareToQuit()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@MainActor
private final class DockAction: NSMenuItem {
    private let handler: @MainActor () -> Void
    init(_ title: String, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("unused") }
    @objc private func run() { handler() }
}

struct NosyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared
    var body: some Scene {
        Window("Nosy", id: "main") {
            MainView(model: model)
                .onAppear { model.launch() }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                FileCommands(model: model)
            }
        }
        Window("Transcripts", id: "library") {
            LibraryView(model: model)
        }
        .defaultSize(width: 860, height: 600)
        Window("Welcome to Nosy", id: "welcome") {
            OnboardingView(model: model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        Settings {
            SettingsView(model: model)
        }
    }
}

private struct FileCommands: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button(model.phase == .done ? "Record Another" : "Start Recording") {
            if model.phase == .done { model.phase = .idle }
            else { model.start() }
        }
        .keyboardShortcut("r", modifiers: .command)
        .tip(model.phase == .done ? "Record another" : "Start recording")
        .disabled(model.recording || model.transitioning || (model.phase != .done && !model.canStart))
        Button("Add Marker") { model.addMarker() }
            .keyboardShortcut(model.recording ? KeyboardShortcut("m", modifiers: .command) : nil)
            .tip("Mark this moment")
            .disabled(!model.recording || model.transitioning)
        Divider()
        Button("Transcripts") { openWindow(id: "library") }.keyboardShortcut("t", modifiers: .command).tip("Open transcripts")
        Button("Import Recording…") { model.importRecording() }
            .keyboardShortcut("i", modifiers: .command)
            .tip("Import audio")
            .disabled(model.busy)
        Button("Open Transcripts Folder") { model.revealTranscriptsFolder() }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .tip("Show save folder")
        Divider()
        Button("Set Up Nosy…") { openWindow(id: "welcome") }.tip("Open setup")
    }
}

struct MainView: View {
    @ObservedObject var model: AppModel
    var bodyHeightLimit: CGFloat?
    var previewDropdown: Dropdown?
    var previewTranscribingHome = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focus: Field?
    @State private var dropping = false
    @State private var titlebarInset: CGFloat = 0
    @State private var homeFromTranscribing = false
    @State private var openDropdown: Dropdown?
    @State private var dropdownFrame = CGRect.zero
    @State private var vocabularyDraft: VocabularyDraft?
    @State private var vocabularyDrafts: [URL: VocabularyDraft] = [:]
    enum Field { case lecture, session }
    enum Dropdown: Hashable {
        case saveTo, session, vocabulary
        var accessibilityTitle: String {
            switch self {
            case .saveTo: "Save to"
            case .session: "Session"
            case .vocabulary: "Vocabulary"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            titlebar.zIndex(3)
            if showsTranscribingScreen {
                StagePanel(model: model, onHome: { homeFromTranscribing = true })
                    .padding(16).card().padding(.horizontal, 20).padding(.vertical, 16)
            } else {
                if model.phase == .idle { captureMode }
                ViewThatFits(in: .vertical) {
                    details
                    ScrollView { details }.scrollBounceBehavior(.basedOnSize)
                }
                .frame(maxHeight: bodyHeightLimit ?? max(180, (NSScreen.main?.visibleFrame.height ?? 800) - 240))
                .padding(.bottom, 12)
                .dropDestination(for: URL.self) { urls, _ in
                    guard let url = urls.first, !model.busy else { return false }
                    model.importRecording(url)
                    return true
                } isTargeted: { dropping = $0 && !model.busy }
                controls.padding(.horizontal, 20).padding(.bottom, 16)
            }
        }
        .frame(width: 400)
        .fixedSize(horizontal: true, vertical: true)
        .background(WindowBackdrop())
        .background(MainWindowChrome(titlebarInset: $titlebarInset))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.panelBorder.opacity(0.78)).allowsHitTesting(false))
        .padding(.top, -titlebarInset)
        .coordinateSpace(name: "nosyMainWindow")
        .background(DropdownDismissMonitor(active: openDropdown != nil, panelFrame: dropdownFrame) { closeDropdown() })
        .tint(Theme.accentText)
        .animation(Motion.state(reduceMotion), value: model.phase)
        .animation(Motion.state(reduceMotion), value: model.paused)
        .animation(Motion.state(reduceMotion), value: model.selectedLecture == "__new__")
        .animation(Motion.state(reduceMotion), value: model.active?.id)
        .animation(dropdownAnimation, value: openDropdown)
        .onAppear {
            model.openWindow = openWindow
            if previewTranscribingHome { homeFromTranscribing = true }
            if let previewDropdown { showDropdown(previewDropdown) }
            if model.needsOnboarding && !Snapshot.isRunning { openWindow(id: "welcome") }
        }
        .onPreferenceChange(DropdownFramePreference.self) { dropdownFrame = $0 }
        .onChange(of: model.selectedLecture) { _, lecture in
            if lecture == "__new__" { focus = .lecture }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshSavedTranscript()
        }
        .onChange(of: model.phase) { _, phase in
            if phase != .transcribing { homeFromTranscribing = false }
            if phase == .recording || phase == .done { closeDropdown() }
        }
        .onExitCommand { closeDropdown() }
    }

    private var showsTranscribingScreen: Bool {
        model.phase == .transcribing && !homeFromTranscribing
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 14) {
            banners
            if model.phase != .recording && model.phase != .done { fields.zIndex(2) }
            StagePanel(model: model, dropping: dropping,
                       showReady: homeFromTranscribing && model.phase == .transcribing,
                       onHome: {
                           homeFromTranscribing = true
                       })
        }
        .padding(.horizontal, 20).padding(.top, 10)
        .fixedSize(horizontal: false, vertical: true)
    }

    // The traffic lights own the leading corner; keep the app mark beside them and utilities at the trailing edge.
    private var titlebar: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: 56).accessibilityHidden(true)
            HStack(spacing: 6) {
                NosyMark(size: 18)
                Text("Nosy").font(Theme.display(13, .semibold)).foregroundStyle(Theme.ink)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            HStack(spacing: 0) {
                Button { openWindow(id: "library") } label: { Image(systemName: "doc.text") }
                    .buttonStyle(IconButtonStyle(size: 24))
                    .tip("Open transcripts", edge: .bottom)
                    .accessibilityLabel("Show transcripts")
                Button { model.chooseTranscriptsFolder() } label: { Image(systemName: "folder") }
                    .buttonStyle(IconButtonStyle(size: 24))
                    .tip("Change folder", edge: .bottom)
                    .accessibilityLabel("Choose where transcripts are saved, currently \(model.paths.transcripts.lastPathComponent)")
                    .disabled(model.working)
                Button { NSWorkspace.shared.open(URL(string: "https://github.com/bardya07/nosy")!) } label: {
                    Image(nsImage: Self.githubMark)
                        .renderingMode(.template)
                        .resizable().interpolation(.high).scaledToFit()
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(IconButtonStyle(size: 24))
                .tip("Open GitHub", edge: .bottom)
                .accessibilityLabel("Open Nosy on GitHub")
            }
            StatusPill(model: model).fixedSize()
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private static let githubMark = Bundle.main.image(forResource: "GitHubMark") ?? NSImage()

    private var captureMode: some View {
        VStack(spacing: 7) {
            CaptureModePicker(model: model)
            Text(modeCaption)
                .font(Theme.mono(11))
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.92)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16).padding(.top, 10)
    }

    private var modeCaption: String {
        switch model.recordingSource {
        case .mic: "Records your microphone — the room around you."
        case .both: "Records your Mac's audio plus your mic — calls, videos."
        case .macAudio: "Records your Mac's audio — calls, videos."
        }
    }

    @ViewBuilder private var banners: some View {
        if !model.recording, let setup = model.setupMessage {
            Banner(symbol: "exclamationmark.triangle.fill", tint: Theme.amber, text: setup) {
                HStack(spacing: 14) {
                    Button("Set up…") { openWindow(id: "welcome") }.buttonStyle(LinkButtonStyle(tint: Theme.ink)).tip("Open setup")
                    Button("Check again") { model.refreshDependencies() }.buttonStyle(LinkButtonStyle(tint: Theme.muted)).tip("Check setup")
                }
            }.transition(.soft(reduceMotion))
        }
        if !model.recording, let record = model.recovery.first {
            Banner(symbol: "arrow.counterclockwise", tint: Theme.amber,
                   text: "Unfinished recording: \(record.lecture) · \(record.session), \(Core.minutes(Core.audioDuration(id: record.id, paths: model.paths))) min"
                    + (model.recovery.count > 1 ? " (+\(model.recovery.count - 1) more)" : "")) {
                HStack(spacing: 14) {
                    Button("Transcribe now") { model.retry(record) }.buttonStyle(LinkButtonStyle(tint: Theme.ink)).tip("Retry transcription")
                    Button("Later") { model.postponeRecovery() }.buttonStyle(LinkButtonStyle(tint: Theme.muted))
                        .tip("Keep unfinished")
                    Button("Delete…") { model.deleteRecording(record) }.buttonStyle(LinkButtonStyle(tint: Theme.coral)).tip("Delete audio")
                }.disabled(model.busy)
            }.transition(.soft(reduceMotion))
        }
        if (model.phase != .failed || model.macAudioDenied), (!model.recording || (!model.stalled && !model.silenceWarning)), let error = model.errorMessage {
            Banner(symbol: "exclamationmark.circle.fill", tint: Theme.coral, text: error) {
                HStack(spacing: 14) {
                    if model.macAudioDenied {
                        Button("Open Mac Audio Settings") { model.openMacAudioSettings() }.buttonStyle(LinkButtonStyle(tint: Theme.ink)).tip("Mac audio privacy")
                    }
                    if model.microphoneDenied {
                        Button("Open Microphone Settings") { model.openMicrophoneSettings() }.buttonStyle(LinkButtonStyle(tint: Theme.ink)).tip("Microphone privacy")
                    }
                    Button("Dismiss") { model.clearError() }.buttonStyle(LinkButtonStyle(tint: Theme.muted)).tip("Dismiss message")
                }
            }
            .tip("Error details")
            .transition(.soft(reduceMotion))
        }
        if (!model.recording || (!model.stalled && !model.silenceWarning && model.errorMessage == nil)), let notice = model.sleepNotice {
            Banner(symbol: "moon.zzz.fill", tint: Theme.amber, text: notice) {
                Button("OK") { model.sleepNotice = nil }.buttonStyle(LinkButtonStyle(tint: Theme.muted)).tip("Dismiss notice")
            }.transition(.soft(reduceMotion))
        }
        if model.recording, !model.paused, model.macAudioQuiet, !model.macAudioDenied {
            Banner(symbol: "speaker.wave.2", tint: Theme.muted,
                   text: "Mac audio is silent. If other apps are playing or you denied access, enable Nosy in System Settings → Privacy & Security → Screen & System Audio Recording.") {
                Button("Open Mac Audio Settings") { model.openMacAudioSettings() }.buttonStyle(LinkButtonStyle(tint: Theme.ink)).tip("Mac audio privacy")
            }
        }
        if model.stalled {
            Banner(symbol: "waveform.slash", tint: Theme.coral, text: model.recordingSource.usesMacAudio ? "Nosy lost a recording source. Check Mac audio access and your connected microphone; Nosy is trying to reconnect." : "Nosy isn't receiving any audio. Check that your microphone is connected.") { EmptyView() }
                .transition(.soft(reduceMotion))
        } else if model.silenceWarning {
            Banner(symbol: "mic.slash.fill", tint: Theme.coral, text: "Nosy can't hear anything. Check your microphone.") { EmptyView() }
                .transition(.soft(reduceMotion))
        }
    }

    private var fields: some View {
        VStack(spacing: 8) {
            HStack(spacing: 7) {
                controlButton(.saveTo, icon: "folder", value: folderTitle, truncation: .middle)
                controlButton(.session, icon: "pencil", value: model.session, truncation: .tail)
                controlButton(.vocabulary, icon: "book.closed", value: model.vocabularySubject, truncation: .tail)
            }
            if let openDropdown {
                dropdownContent(openDropdown)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key: DropdownFramePreference.self,
                                               value: geometry.frame(in: .named("nosyMainWindow")))
                    })
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else {
                Color.clear.frame(height: 0)
                    .preference(key: DropdownFramePreference.self, value: .zero)
            }
        }
        .disabled(model.busy)
    }

    private var folderTitle: String {
        model.selectedLecture == "__new__" ? (model.newLecture.isEmpty ? "New folder" : model.newLecture) : model.selectedLecture
    }

    private func controlButton(_ control: Dropdown, icon: String, value: String, truncation: Text.TruncationMode) -> some View {
        Button { toggleDropdown(control) } label: {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.muted)
                    .accessibilityHidden(true)
                Text(value).font(Theme.mono(10.5, .medium)).foregroundStyle(Theme.ink)
                    .lineLimit(1).truncationMode(truncation).layoutPriority(-1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(Theme.muted)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity).frame(height: 34)
            .background(Theme.raised, in: Capsule())
            .overlay(Capsule().strokeBorder(openDropdown == control ? Theme.accentText.opacity(0.72) : Theme.line,
                                             lineWidth: openDropdown == control ? 1.2 : 1))
            .contentShape(Capsule())
        }
        .focusEffectDisabled()
        .buttonStyle(CompactControlButtonStyle())
        .disabled(control == .vocabulary && model.lectureName.trimmingCharacters(in: .whitespaces).isEmpty)
        .accessibilityLabel("\(control.accessibilityTitle): \(value)")
        .accessibilityHint("Opens \(control.accessibilityTitle.lowercased()) controls")
    }

    @ViewBuilder private func dropdownContent(_ control: Dropdown) -> some View {
        switch control {
        case .saveTo:
            VStack(spacing: 2) {
                ForEach(model.lectures, id: \.self) { lecture in
                    Button {
                        model.selectedLecture = lecture
                        closeDropdown()
                    } label: {
                        HStack(spacing: 8) {
                            if model.selectedLecture == lecture {
                                Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.accentText).frame(width: 14)
                            } else {
                                Color.clear.frame(width: 14, height: 10)
                            }
                            Text(lecture).font(Theme.mono(11)).foregroundStyle(Theme.ink)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8).frame(height: 28)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(InsetButtonStyle())
                    .accessibilityLabel("Save to \(lecture)")
                }
                if !model.lectures.isEmpty { Rectangle().fill(Theme.line).frame(height: 1).padding(.vertical, 3) }
                Button {
                    model.selectedLecture = "__new__"
                    model.newLecture = ""
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.accentText).frame(width: 14)
                        Text("New folder…").font(Theme.mono(11)).foregroundStyle(Theme.ink)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8).frame(height: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(InsetButtonStyle())
                if model.selectedLecture == "__new__" {
                    TextField("", text: $model.newLecture, prompt: Text("Name your folder").foregroundStyle(Theme.faint))
                        .textFieldStyle(.plain).font(Theme.mono(11)).foregroundStyle(Theme.ink)
                        .focused($focus, equals: .lecture)
                        .padding(.horizontal, 9).frame(height: 32)
                        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 7))
                        .accessibilityLabel("New folder name")
                        .onSubmit {
                            guard !model.newLecture.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                            showDropdown(.session)
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(8)
            .frame(maxHeight: 190)
            .card(Theme.surface, radius: 12)
            .accessibilityElement(children: .contain)
        case .session:
            HStack(spacing: 9) {
                Image(systemName: "calendar").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.muted)
                    .accessibilityHidden(true)
                TextField("", text: Binding(get: { model.session }, set: { model.session = $0; model.sessionEdited = true }),
                          prompt: Text("Session name").foregroundStyle(Theme.faint))
                    .textFieldStyle(.plain).font(Theme.mono(12)).foregroundStyle(Theme.ink)
                    .focused($focus, equals: .session)
                    .padding(.horizontal, 9).frame(height: 34)
                    .background(Theme.raised, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(focus == .session ? Theme.accentText : Theme.line,
                                                                             lineWidth: focus == .session ? 1.4 : 1))
                    .background(SessionCaretPositioner(focused: focus == .session))
                    .accessibilityLabel("Session name")
                    .onSubmit { closeDropdown() }
            }
            .padding(10).card(Theme.surface, radius: 12)
        case .vocabulary:
            if let vocabularyDraft {
                VocabularyEditor(draft: vocabularyDraft, close: { closeDropdown() }, inline: true)
                    .card(Theme.surface, radius: 12)
            }
        }
    }

    private var dropdownAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.18) : .spring(response: 0.35, dampingFraction: 0.75)
    }

    private func toggleDropdown(_ control: Dropdown) {
        if openDropdown == control { closeDropdown() }
        else { showDropdown(control) }
    }

    private func showDropdown(_ control: Dropdown) {
        if openDropdown == .vocabulary { vocabularyDraft?.flush() }
        if control == .saveTo { model.refreshLectures() }
        if control == .vocabulary { prepareVocabularyDraft() }
        withAnimation(dropdownAnimation) { openDropdown = control }
        switch control {
        case .session: focus = .session
        case .saveTo: focus = model.selectedLecture == "__new__" ? .lecture : nil
        case .vocabulary: focus = nil
        }
    }

    private func closeDropdown() {
        if openDropdown == .vocabulary { vocabularyDraft?.flush() }
        withAnimation(dropdownAnimation) { openDropdown = nil }
        focus = nil
    }

    private func prepareVocabularyDraft() {
        let lecture = model.lectureName
        guard let url = model.vocabularyURL(for: lecture) else { vocabularyDraft = nil; return }
        if let retained = vocabularyDrafts[url], retained.hasChanges {
            vocabularyDraft = retained
        } else {
            let loaded = VocabularyDraft(lecture: lecture, folder: url.deletingLastPathComponent()) {
                model.refreshLectures()
            }
            vocabularyDrafts[url] = loaded
            vocabularyDraft = loaded
        }
    }

    @ViewBuilder private var controls: some View {
        HStack(spacing: 10) {
            if model.recording {
                Button { model.togglePause() } label: {
                    Text(model.paused ? "Resume" : "Pause").lineLimit(1).fixedSize()
                }
                .buttonStyle(PillButtonStyle(kind: .quiet, height: 46, horizontalPadding: 12))
                .frame(width: 96)
                .keyboardShortcut("p", modifiers: .command)
                .tip(model.paused ? "Resume recording" : "Pause recording", edge: .top)
                .accessibilityLabel(model.paused ? "Resume recording" : "Pause recording")
                .disabled(model.transitioning)
                .transition(.soft(reduceMotion))
            }
            MicMenu(model: model)
                .disabled(model.micLocked)
                .accessibilityLabel("Change recording source or microphone")
            Button(action: primaryAction) {
                HStack(spacing: 10) {
                    Text(primaryTitle).lineLimit(1).fixedSize()
                    if !model.recording {
                        Text("⌘R").font(Theme.mono(11, .medium)).opacity(0.6)
                    }
                }
            }
            .buttonStyle(PillButtonStyle(kind: model.recording ? .dark : .primary, height: model.recording ? 46 : 48))
            // Return starts; stopping takes ⌘Return so a stray keypress cannot end a lecture.
            .keyboardShortcut(.return, modifiers: model.recording ? .command : [])
            .tip(model.recording ? "Stop and transcribe" : (model.phase == .done ? "Record another" : "Start recording"))
            .disabled(model.recording ? model.transitioning : (model.phase != .done && !model.canStart))
        }
    }
    private func primaryAction() {
        focus = nil
        if model.recording { model.stop() }
        else if model.phase == .done { model.phase = .idle }
        else { model.start() }
    }
    private var primaryTitle: String {
        if model.recording { return "Stop & transcribe" }
        switch model.phase {
        case .done: return "Record another"
        default: return "Start recording"
        }
    }
}

private struct DropdownFramePreference: PreferenceKey {
    static let defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

@MainActor
private struct SessionCaretPositioner: NSViewRepresentable {
    var focused: Bool
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }
    func updateNSView(_ view: NSView, context: Context) { context.coordinator.update(view: view, focused: focused) }

    @MainActor
    final class Coordinator {
        weak var view: NSView?
        private var wasFocused = false
        func update(view: NSView, focused: Bool) {
            self.view = view
            guard focused, !wasFocused else { wasFocused = focused; return }
            wasFocused = true
            DispatchQueue.main.async { [weak self] in
                guard let editor = self?.view?.window?.firstResponder as? NSTextView else { return }
                editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
            }
        }
    }
}

// A local mouse monitor dismisses the inline panel while leaving the click itself
// available to the control the user chose next.
@MainActor
private struct DropdownDismissMonitor: NSViewRepresentable {
    var active: Bool
    var panelFrame: CGRect
    var onOutside: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.view = view
        context.coordinator.update(active: active, panelFrame: panelFrame, onOutside: onOutside)
        context.coordinator.install()
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.view = view
        context.coordinator.update(active: active, panelFrame: panelFrame, onOutside: onOutside)
    }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.stop() }

    @MainActor
    final class Coordinator {
        weak var view: NSView?
        private var monitor: Any?
        private var active = false
        private var panelFrame = CGRect.zero
        private var onOutside: () -> Void = {}

        func update(active: Bool, panelFrame: CGRect, onOutside: @escaping () -> Void) {
            self.active = active
            self.panelFrame = panelFrame
            self.onOutside = onOutside
        }
        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, self.active else { return event }
                guard let view = self.view, let eventWindow = event.window, eventWindow === view.window else {
                    self.onOutside()
                    return event
                }
                let point = view.convert(event.locationInWindow, from: nil)
                let swiftUIPoint = CGPoint(x: point.x, y: view.bounds.height - point.y)
                if !self.panelFrame.insetBy(dx: -4, dy: -4).contains(swiftUIPoint) { self.onOutside() }
                return event
            }
        }
        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        }
    }
}

struct NosyMark: View {
    var size: CGFloat
    private static let image = Bundle.main.image(forResource: "NosyMark") ?? NSApp?.applicationIconImage ?? NSImage()
    var body: some View {
        Image(nsImage: Self.image).resizable().interpolation(.high)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size / 4, style: .continuous))
            .shadow(color: Theme.stop.opacity(0.3), radius: 5, y: 2)
            .accessibilityHidden(true)
    }
}

struct FieldLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).font(Theme.label).kerning(0.8).foregroundStyle(Theme.muted)
    }
}

private struct CaptureModePicker: View {
    @ObservedObject var model: AppModel
    @Namespace private var selectionNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var selected: RecordingSource? {
        switch model.recordingSource {
        case .mic: .mic
        case .both: .both
        case .macAudio: nil
        }
    }
    var body: some View {
        HStack(spacing: 3) {
            modeButton("In-person", source: .mic, active: selected == .mic)
            if RecordingSource.macAudioAvailable {
                modeButton("Virtual", source: .both, active: selected == .both)
            }
        }
        .padding(3)
        .background(Theme.surface.opacity(0.68), in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.line, lineWidth: 1))
        .disabled(model.micLocked)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recording mode")
        .animation(reduceMotion ? .easeOut(duration: 0.18) : .spring(response: 0.35, dampingFraction: 0.65), value: selected)
    }
    private func modeButton(_ title: String, source: RecordingSource, active: Bool) -> some View {
        Button { model.selectSource(source) } label: {
            ZStack {
                if active {
                    Capsule().fill(Theme.raised)
                        .matchedGeometryEffect(id: "capture-mode-selection", in: selectionNamespace)
                }
                Text(title).font(Theme.mono(11, .medium))
                    .foregroundStyle(active ? Theme.ink : Theme.muted)
                    .frame(maxWidth: .infinity).frame(height: 28)
            }
        }
        .focusEffectDisabled()
        .buttonStyle(ModePickerButtonStyle())
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

private struct ModePickerButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.965 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.72), value: configuration.isPressed)
    }
}

private struct CompactControlButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CompactControlBody(configuration: configuration)
    }
    private struct CompactControlBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.isFocused) private var focused
        @State private var hovering = false
        var body: some View {
            configuration.label
                .brightness(hovering && !configuration.isPressed ? 0.025 : 0)
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.975 : 1)
                .overlay(Capsule().strokeBorder(focused ? Theme.accentText : .clear, lineWidth: 2).padding(-2))
                .onHover { inside in withAnimation(Motion.hover) { hovering = inside } }
                .animation(Motion.press, value: configuration.isPressed)
        }
    }
}

private struct MicMenu: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Menu {
            if RecordingSource.macAudioAvailable {
                Section("Mode") {
                    Button { model.selectSource(.mic) } label: { checked(model.recordingSource == .mic, "In-person · Microphone") }
                        .tip("Select in-person")
                    Button { model.selectSource(.both) } label: { checked(model.recordingSource == .both, "Virtual · Mic + Mac audio") }
                        .tip("Select virtual")
                }
                Section("Advanced") {
                    Button { model.selectSource(.macAudio) } label: { checked(model.recordingSource == .macAudio, "Mac audio only") }
                        .tip("Mac audio only")
                }
                Divider()
            }

            Button { model.selectInput(nil) } label: {
                checked(model.inputUID == nil, "System default" + (model.systemInput.map { " (\($0.name))" } ?? ""))
            }
            .tip("Use system default")
            if !model.inputs.isEmpty { Divider() }
            ForEach(model.inputs) { device in
                Button { model.selectInput(device.id) } label: { checked(model.inputUID == device.id, device.name) }
                    .tip("Select microphone")
            }
        } label: {
            Image(systemName: model.inputUID == nil || Snapshot.isRunning ? "mic" : "mic.fill")
        }
        .menuStyle(.button)
        .font(Theme.mono(11))
        .buttonStyle(IconButtonStyle(size: 24, active: model.inputUID != nil && !Snapshot.isRunning))
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { if $0 { model.refreshInputs() } }
        .tip(model.microphoneName)
        .accessibilityLabel("Choose recording source or microphone, currently \(model.inputName)")
    }
    @ViewBuilder private func checked(_ on: Bool, _ title: String) -> some View {
        if on { Label(title, systemImage: "checkmark") } else { Text(title) }
    }
}

private struct StatusPill: View {
    @ObservedObject var model: AppModel
    @ViewBuilder
    var body: some View {
        if let title {
            HStack(spacing: 6) {
                if model.recording {
                    Circle().fill(model.paused ? Theme.amber : Theme.coral).frame(width: 7, height: 7)
                        .opacity(model.paused || model.level > -50 ? 1 : 0.5)
                }
                Text(title).font(Theme.mono(10, .medium)).foregroundStyle(tint)
                    .contentTransition(.opacity)
            }
            .frame(height: 24)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Status: \(title)")
        }
    }
    private var title: String? {
        switch model.phase {
        case .idle, .done, .failed: nil
        case .recording: model.paused ? "Paused" : "REC"
        case .transcribing: model.transcriptionPauseReason != nil ? "Paused" : (model.waiting ? "Queued" : "Transcribing")
        }
    }
    private var tint: Color {
        switch model.phase {
        case .idle: Theme.muted
        case .recording: model.paused ? Theme.amber : Theme.recordingText
        case .transcribing: Theme.amber
        case .done: model.savedSummary.noSpeech || model.savedSummary.markdown == nil ? Theme.muted : Theme.savedText
        case .failed: Theme.coral
        }
    }
}

struct Banner<Actions: View>: View {
    let symbol: String
    let tint: Color
    let text: String
    @ViewBuilder let actions: () -> Actions
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 13, weight: .bold)).foregroundStyle(tint).frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(text).font(Theme.text(12.5, .medium)).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
                actions()
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .card(tint.opacity(0.12), radius: 14)
        .accessibilityElement(children: .contain)
    }
}

// The middle of the window: what Nosy is doing right now.
struct StagePanel: View {
    @ObservedObject var model: AppModel
    var dropping = false
    var showReady = false
    var onHome: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            switch model.phase {
            case .idle: idle.transition(.soft(reduceMotion))
            case .recording: recording.transition(.soft(reduceMotion))
            case .transcribing:
                if showReady { idle.transition(.soft(reduceMotion)) }
                else { transcribing.transition(.soft(reduceMotion)) }
            case .done: done.transition(.soft(reduceMotion))
            case .failed: failed.transition(.soft(reduceMotion))
            }
        }
        .frame(maxWidth: .infinity)
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 12).fill(Theme.surface)
                RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.accentText, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                Text("Drop to transcribe").font(Theme.text(14, .semibold)).foregroundStyle(Theme.navy)
            }
        }
        .animation(Motion.hover, value: dropping)
    }

    private var idle: some View {
        EmptyView()
    }

    private var recording: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("\(model.current?.lecture ?? model.lectureName) · \(model.current?.session ?? model.session)")
                    .font(Theme.mono(12)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                if model.recordingSource == .both {
                    Text("Virtual").font(Theme.mono(9, .medium)).foregroundStyle(Theme.accentText)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(Core.timer(model.duration))
                    .font(Theme.mono(44)).tracking(-1.32)
                    .foregroundStyle(model.paused ? Theme.muted : Theme.navy)
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: Int(model.duration))
                    .accessibilityLabel("Recorded \(Core.timer(model.duration))")
            }
            Waveform(levels: model.levels, tint: Theme.wavePlayed, active: !model.paused)
                .frame(height: 24).padding(.horizontal, 20).frame(height: 44)
                .background(Theme.waveform, in: Capsule())
                .accessibilityLabel("Live recording input").accessibilityValue("\(Int(model.level)) decibels")
            RecordingMarkers(model: model)
            if let active = model.active {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(model.transcriptionPauseReason.map { "Paused — \($0)" } ?? "Also transcribing \(active.lecture) · \(Int((model.transcriptionProgress * 100).rounded()))%")
                        .font(Theme.text(11, .medium)).foregroundStyle(Theme.muted).lineLimit(2)
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading).card()
            }
        }
    }

    private var transcribing: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !model.waiting {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(Int((model.transcriptionProgress * 100).rounded()))%")
                        .font(Theme.text(13, .semibold)).monospacedDigit().foregroundStyle(Theme.ink)
                        .contentTransition(.numericText())
                    Spacer(minLength: 8)
                    ProgressTrack(value: model.transcriptionProgress, tint: Theme.stop)
                        .frame(width: 210)
                }
            } else {
                ProgressView().progressViewStyle(.linear).tint(Theme.stop)
            }
            Text(remainingText).font(Theme.text(12)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
            HStack {
                Text("This might take a minute.").font(Theme.text(11)).foregroundStyle(Theme.muted)
                Spacer(minLength: 4)
                Button("Home", systemImage: "house") { onHome() }
                    .buttonStyle(LinkButtonStyle(tint: Theme.navy))
                    .tip("Return to ready")
                    .accessibilityLabel("Home while transcribing")
            }
        }
    }
    private var remainingText: String {
        if let reason = model.transcriptionPauseReason { return "Paused — \(reason)" }
        if model.waiting {
            if let active = model.active { return "Starts when \(active.lecture) · \(active.session) finishes" }
            return "Waiting to start"
        }
        guard let remaining = model.transcriptionRemaining else { return "Getting started… \(Core.timer(model.transcriptionElapsed)) elapsed" }
        let minutes = Int((remaining / 60).rounded(.up))
        return remaining < 60 ? "Less than a minute left" : "About \(minutes) min left"
    }

    private var done: some View {
        SavedPanel(model: model)
    }

    private var failed: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark").font(.system(size: 17, weight: .heavy)).foregroundStyle(Theme.coral)
                .frame(width: 38, height: 38).background(Theme.coral.opacity(0.14), in: Circle())
                .accessibilityHidden(true)
            Text(model.errorMessage ?? "Something went wrong")
                .font(Theme.text(13, .medium)).foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .tip("Error details")
                .textSelection(.enabled)
            HStack(spacing: 16) {
                if model.microphoneDenied {
                    Button("Open Microphone Settings") { model.openMicrophoneSettings() }.buttonStyle(LinkButtonStyle()).tip("Microphone privacy")
                }
                if let record = model.current {
                    Button("Retry") { model.retry() }.buttonStyle(LinkButtonStyle()).tip("Retry transcription").disabled(model.isQueued(record.id))
                }
            }
        }.padding(14).frame(maxWidth: .infinity).card()
    }
}

private struct RecordingMarkers: View {
    @ObservedObject var model: AppModel
    @FocusState private var focusedMarker: Int?
    @State private var confirming = false
    private var markers: [SessionMarker] { model.current?.markers ?? [] }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button(action: markMoment) {
                    Label(confirming ? "Marked" : "Mark moment", systemImage: confirming ? "checkmark" : "bookmark")
                        .font(Theme.mono(11, .medium))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(PillButtonStyle(kind: .dark, height: 34, fullWidth: false, horizontalPadding: 12))
                .tip("Mark this moment")
                .accessibilityLabel(confirming ? "Moment marked" : "Mark moment")
                .disabled(model.transitioning)
                Spacer(minLength: 0)
            }
            if !markers.isEmpty {
                ScrollViewReader { scroll in
                    ScrollView {
                        VStack(spacing: 5) {
                            ForEach(markers.indices, id: \.self) { index in
                                HStack(spacing: 10) {
                                    Text(Core.timer(markers[index].t)).font(Theme.mono(12)).foregroundStyle(Theme.muted)
                                    TextField("Marker", text: Binding(
                                        get: { markers.indices.contains(index) ? markers[index].label : "" },
                                        set: { model.editMarker(at: index, label: $0) }))
                                        .textFieldStyle(.plain).font(Theme.text(14)).foregroundStyle(Theme.ink)
                                        .focused($focusedMarker, equals: index)
                                        .onSubmit { focusedMarker = nil }
                                        .accessibilityLabel("Marker at \(Core.timer(markers[index].t))")
                                        .tip("Edit marker")
                                }.frame(height: 20).id(index)
                            }
                        }
                    }
                    .frame(height: CGFloat(min(markers.count, 3) * 25 - 5))
                    .onChange(of: markers.count) { old, count in
                        if count > old {
                            scroll.scrollTo(count - 1, anchor: .bottom)
                            focusedMarker = count - 1
                        }
                    }
                }
            }
        }
    }
    private func markMoment() {
        let count = markers.count
        model.addMarker()
        guard markers.count > count else { return }
        withAnimation(Motion.state) { confirming = true }
        Task {
            try? await Task.sleep(for: .milliseconds(850))
            withAnimation(Motion.hover) { confirming = false }
        }
    }
}

private struct SavedPanel: View {
    @ObservedObject var model: AppModel
    private var summary: SavedSummary { model.savedSummary }
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: summary.noSpeech ? "waveform.slash" : (summary.markdown == nil ? "doc" : "checkmark"))
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(summary.noSpeech || summary.markdown == nil ? Theme.muted : .white)
                    .frame(width: 40, height: 40)
                    .background(summary.noSpeech || summary.markdown == nil ? Theme.surface : Theme.green, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.noSpeech ? "No speech detected" : (summary.markdown == nil ? "Transcript unavailable" : "Transcript saved"))
                        .font(Theme.display(summary.noSpeech || summary.markdown == nil ? 18 : 20, .bold))
                        .tracking(-0.4).foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(model.current?.lecture ?? model.lectureName) · \(savedSession)")
                        .font(Theme.mono(11)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
                }
            }
            Text(statLine)
                .font(Theme.mono(11)).foregroundStyle(Theme.ink)
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10).padding(.horizontal, 12).card()
            HStack(spacing: 8) {
                Button("Open") { model.showInLibrary(model.current?.transcriptPath.map { URL(fileURLWithPath: $0) }) }
                    .tip("Open transcript")
                    .fixedSize()
                Button("Show in Finder") { model.revealTranscript() }
                    .tip("Show in Finder")
                    .fixedSize()
                Button(copied ? "Copied" : "Copy") {
                    model.refreshSavedTranscript()
                    guard let text = model.savedSummary.markdown else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.4)); copied = false }
                }
                .tip(copied ? "Transcript copied" : "Copy transcript")
                .fixedSize()
                .disabled(summary.markdown == nil)
            }
            .buttonStyle(PillButtonStyle(kind: .quiet, height: 38, fullWidth: false, horizontalPadding: 10))
            .frame(maxWidth: .infinity, alignment: .center)
            .disabled(summary.markdown == nil)
        }
    }
    private var savedSession: String {
        model.current?.transcriptPath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
            ?? model.current?.session ?? model.session
    }
    private var statLine: String {
        var values = [summary.duration.map { Core.timer($0) } ?? "—"]
        if let words = summary.words { values.append("\(words.formatted()) words") }
        if summary.terms > 0 { values.append("\(summary.vocabHits ?? 0)/\(summary.terms) terms") }
        return values.joined(separator: " · ")
    }
}

// Read existing transcript/audio metadata for presentation.
struct SavedSummary {
    var markdown: String?
    var duration: TimeInterval?
    var words: Int?
    var terms = 0
    var vocabHits: Int?
    var noSpeech: Bool { words == 0 }
    init() {}
    @MainActor init(record: SessionRecord?, model: AppModel) {
        guard let record else { return }
        let audioLength = Core.audioDuration(id: record.id, paths: model.paths)
        let elapsed = record.endedAt.map { $0.timeIntervalSince(record.startedAt) } ?? 0
        duration = audioLength > 0 ? audioLength : (model.duration > 0 ? model.duration : (elapsed > 0 ? elapsed : nil))
        let vocabulary = record.vocabularyTerms ?? []
        terms = vocabulary.count
        guard let path = record.transcriptPath, let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        markdown = text
        let spoken = Core.spokenText(text)
        words = Core.wordCount(text)
        vocabHits = vocabulary.filter { term in
            spoken.range(of: "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: term) + "(?![\\p{L}\\p{N}])",
                         options: [.regularExpression, .caseInsensitive]) != nil
        }.count
    }
}

// Rolling recent input levels, newest at right. This is a meter, never live transcription.
struct Waveform: View {
    let levels: [Double]
    let tint: Color
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Canvas { context, size in
            guard !levels.isEmpty else { return }
            let gap: CGFloat = 3
            let width = max(1.5, (size.width - gap * CGFloat(levels.count - 1)) / CGFloat(levels.count))
            for (index, db) in levels.enumerated() {
                let normalized = active ? min(1, max(0, (db + 55) / 50)) : 0
                let height = max(3, size.height * CGFloat(normalized))
                let rect = CGRect(x: CGFloat(index) * (width + gap), y: (size.height - height) / 2, width: width, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: width / 2), with: .color(active && db > -55 ? tint : Theme.waveIdle))
            }
        }
        .animation(reduceMotion ? nil : .linear(duration: 0.1), value: levels)
    }
}

struct ProgressTrack: View {
    let value: Double
    let tint: Color
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.line)
                Capsule().fill(tint).frame(width: max(8, geometry.size.width * min(1, max(0, value))))
            }
        }
        .frame(height: 8)
        .animation(.linear(duration: 0.3), value: value)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
    }
}

#if !NOSY_UI_TEST
@main
enum EntryPoint {
    @MainActor static func main() async {
        Theme.registerFonts()
        if CommandLine.arguments.dropFirst().first == "--headless-snapshot" {
            exit(Snapshot.run(Array(CommandLine.arguments.dropFirst(2))))
        }
        if CommandLine.arguments.dropFirst().first?.hasPrefix("--headless-") == true {
            let code = await Headless.run(Array(CommandLine.arguments.dropFirst()))
            exit(code)
        }
        NosyApp.main()
    }
}
#endif
