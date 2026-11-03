import SwiftUI
import AppKit
import Combine
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
        guard model.working else {
            // Summaries can be the only remaining work. They must cancel and reap their CLI too.
            guard model.summaries.hasPendingWork || model.finishOnboardingWork != nil || model.hasEncoderWork else { return .terminateNow }
            Task { await model.prepareToQuit(); sender.reply(toApplicationShouldTerminate: true) }
            return .terminateLater
        }
        let alert = NSAlert()
        alert.messageText = model.recording ? "A recording is still in progress. Quit anyway?"
            : model.importsInProgress > 0 ? "Audio is still importing. Quit anyway?"
            : model.active != nil || !model.queue.isEmpty ? "A recording is still transcribing. Quit anyway?" : "Nosy is still working. Quit anyway?"
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
            WorkspaceView(model: model)
                .onAppear { model.launch() }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 400, height: 300)
        .commands {
            CommandGroup(replacing: .newItem) { FileCommands(model: model) }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { model.workspace.showSettings(); delegate.showWindow() }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

struct AudioDropOverlay: View {
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.55))
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Theme.accent.opacity(0.10))
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Theme.accentText, lineWidth: 2)
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.doc.fill")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(Theme.accentText)
                    Text("Drop to transcribe")
                        .font(Theme.text(15, .semibold))
                        .foregroundStyle(Theme.navy)
                }
                .padding(.horizontal, 28).padding(.vertical, 20)
                // Opaque badge: the text behind the drop target must not show through.
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(nsColor: .windowBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.accent.opacity(0.08)).allowsHitTesting(false))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line))
                .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}

private struct FileCommands: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Button("Start Recording") {
            guard model.phase == .idle || model.homeFromTranscribing else { return }
            model.start()
        }
        .keyboardShortcut("r", modifiers: .command)
        .tip("Start recording")
        .disabled((model.phase != .idle && !model.homeFromTranscribing) || model.busy || !model.hasLecture)
        Button("Add Marker") { model.addMarker() }
            .keyboardShortcut(model.recording ? KeyboardShortcut("m", modifiers: .command) : nil)
            .tip("Mark this moment")
            .disabled(!model.recording || model.transitioning)
        Divider()
        Button("Library") { model.showInLibrary(nil) }.keyboardShortcut("l", modifiers: .command).tip("Open Library")
        Button("Import Recording…") { model.importRecording() }
            .keyboardShortcut("i", modifiers: .command)
            .tip("Import audio")
            .disabled(model.busy)
        Button("Open Transcripts Folder") { model.revealTranscriptsFolder() }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .tip("Show save folder")
        Divider()
        Button("Set Up Nosy…") { model.workspace.showSetup() }.tip("Open setup")
    }
}

struct MainView: View {
    @ObservedObject var model: AppModel
    var previewDropdown: Dropdown?
    var previewVocabularyExpanded = false
    var previewSaveToExpanded = false
    var previewFolderListOpen = false
    var previewEnteringNewFolderName = false
    var previewSessionRequired = false
    var previewTranscribingHome = false
    var previewDropping = false
    var previewHoveredFolder: String? = nil
    var onBrowse: (() -> Void)? = nil
    var embedded = false
    var telemetryVisible = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focus: Field?
    @State private var dropping = false
    @State private var openDropdown: Dropdown?
    @State private var saveToExpanded = false
    @State private var enteringNewFolderName = false
    @State private var sessionGate = SessionNameGate()
    @State private var hoveredFolder: String?
    @State private var startShake = 0
    @State private var suppressOutsideDismiss = false
    @State private var dropdownRegions: [CGRect] = []
    @State private var vocabularyDraft: VocabularyDraft?
    @State private var vocabularyDrafts: [URL: VocabularyDraft] = [:]
    enum Field { case lecture, session }
    enum Dropdown: Hashable {
        case session, vocabulary, folders, microphone
        var accessibilityTitle: String {
            switch self {
            case .session: "Session"
            case .vocabulary: "Vocabulary"
            case .folders: "Folders"
            case .microphone: "Microphone"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !embedded { WorkspaceTitlebar(model: model, onHome: goHome).zIndex(20) }
            if model.recording && !embedded {
                RecordingModeBanner(model: model) { showDropdown(.microphone) }
                    .padding(.horizontal, 20).padding(.top, 6)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
            if showsTranscribingScreen {
                StagePanel(model: model, telemetryVisible: telemetryVisible,
                           onHome: { model.homeFromTranscribing = true })
                    .padding(16).card().padding(.horizontal, 20).padding(.vertical, 16)
            } else {
                if model.phase == .idle || model.homeFromTranscribing { captureMode }
                // One instance of the details: duplicate alternatives (ViewThatFits)
                // reset panel state and fight over text focus when they swap.
                details.padding(.bottom, 12)
                controls.padding(.horizontal, 20).padding(.bottom, 16)
            }
        }
        .coordinateSpace(name: Self.space)
        .onPreferenceChange(DropdownRegionKey.self) { dropdownRegions = $0 }
        // Outside clicks close the open panel. The tap ends on mouse-up, after the
        // clicked control has acted, and both rectangles share one SwiftUI space.
        .simultaneousGesture(SpatialTapGesture(coordinateSpace: .named(Self.space)).onEnded { tap in
            guard openDropdown != nil || saveToExpanded || enteringNewFolderName else { return }
            if suppressOutsideDismiss {
                suppressOutsideDismiss = false
            } else if !dropdownRegions.contains(where: { $0.contains(tap.location) }) {
                closeDropdown()
            }
        }, including: openDropdown == nil && !saveToExpanded && !enteringNewFolderName ? .subviews : .all)
        .onExitCommand {
            if openDropdown != nil || saveToExpanded || enteringNewFolderName { closeDropdown() }
        }
        .frame(width: 400)
        .fixedSize(horizontal: true, vertical: true)
        .dropDestination(for: URL.self) { urls, _ in
            guard !model.busy else { return false }
            model.importRecordings(urls)
            return true
        } isTargeted: { dropping = $0 && !model.busy }
        .overlay {
            if dropping { AudioDropOverlay().padding(10).allowsHitTesting(false) }
        }
        .background(WindowBackdrop())
        .background {
            Button("Start recording") { model.start() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled((model.phase != .idle && !model.homeFromTranscribing) || model.busy || !model.hasLecture)
                .opacity(0).frame(width: 0, height: 0)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
        // Tips draw inside the window's clip, so every bubble stays within the rounded window.
        .tipContainerBounds()
        .clipShape(RoundedRectangle(cornerRadius: embedded ? 0 : 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.panelBorder.opacity(embedded ? 0 : 0.78)).allowsHitTesting(false))
        .tint(Theme.accentText)
        .animation(Motion.state(reduceMotion), value: model.phase)
        .animation(Motion.state(reduceMotion), value: model.paused)
        .animation(Motion.state(reduceMotion), value: model.active?.id)
        .animation(Motion.state(reduceMotion), value: openDropdown)
        .animation(Motion.state(reduceMotion), value: saveToExpanded)
        .animation(Motion.state(reduceMotion), value: enteringNewFolderName)
        .onAppear {
            if previewDropping { dropping = true }
            if previewTranscribingHome { model.homeFromTranscribing = true }
            if let previewDropdown { showDropdown(previewDropdown) }
            if previewSaveToExpanded { saveToExpanded = true }
            if previewFolderListOpen {
                saveToExpanded = true
                openDropdown = .folders
            }
            if previewEnteringNewFolderName { enteringNewFolderName = true }
            if previewSessionRequired {
                sessionGate.request()
                showDropdown(.session)
            }
        }
        .onReceive(model.workspace.$homeRequest.dropFirst()) { _ in goHome() }
        .onChange(of: model.sourcePickerRequest) { _, _ in showDropdown(.microphone) }
        .onChange(of: model.startValidationRequest) { _, _ in requestSessionName() }
        .onChange(of: model.session) { _, session in sessionGate.sessionChanged(to: session) }
        .onChange(of: model.selectedLecture) { _, lecture in
            if lecture == "__new__", enteringNewFolderName { focus = .lecture }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshSavedTranscript()
        }
        .onChange(of: model.phase) { _, phase in
            if phase != .transcribing { model.homeFromTranscribing = false }
            // The microphone panel stays open while recording, so its level meter stays live.
            if phase == .done || (phase == .recording && openDropdown != .microphone) { closeDropdown() }
        }
    }

    private static let space = "nosyMain"

    private var showsTranscribingScreen: Bool {
        model.phase == .transcribing && !model.homeFromTranscribing
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 14) {
            banners
            if model.phase != .recording && model.phase != .done { fields }
            if model.phase != .idle || model.homeFromTranscribing {
                StagePanel(model: model,
                           telemetryVisible: telemetryVisible,
                           showReady: model.homeFromTranscribing && model.phase == .transcribing,
                           onHome: {
                               model.homeFromTranscribing = true
                           })
            }
        }
        .padding(.horizontal, 20).padding(.top, 10)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var captureMode: some View {
        VStack(spacing: 7) {
            CaptureModePicker(model: model)
            Text(model.recordingSource.caption)
                .font(Theme.text(11))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .interactionTarget("mode-caption")
        }
        .padding(.horizontal, 16).padding(.top, 10)
    }

    @ViewBuilder private var banners: some View {
        if !model.recording, let setup = model.setupMessage {
            Banner(symbol: "exclamationmark.triangle.fill", tint: Theme.amber, text: setup) {
                HStack(spacing: 14) {
                    Button("Set up…") { model.workspace.showSetup() }.buttonStyle(LinkButtonStyle(tint: Theme.ink)).tip("Open setup")
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
            // Session and Vocabulary keep their identity, so opening the wheel rolls them into bubbles in place.
            HStack(spacing: 7) {
                saveToControl
                if saveToExpanded {
                    folderChoices
                        .transition(reduceMotion ? .opacity : .move(edge: .leading).combined(with: .opacity))
                }
                controlButton(.session, icon: "pencil", value: sessionControlTitle,
                              truncation: .tail, placeholder: sessionIsEmpty, minWidth: 128)
                controlButton(.vocabulary, icon: "book.closed", value: model.vocabularySubject, truncation: .tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(Motion.state(reduceMotion), value: saveToExpanded)
            if enteringNewFolderName {
                newFolderNameEntry
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
            if let openDropdown, openDropdown != .microphone {
                dropdownContent(openDropdown)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                    .interactionTarget("dropdown-panel")
            }
        }
        // The toggles plus the open panel: clicks here never dismiss it.
        .background(GeometryReader { geometry in
            Color.clear.preference(key: DropdownRegionKey.self, value: [geometry.frame(in: .named(Self.space))])
        })
        .background {
            // Escape closes the panel even when nothing inside it has focus.
            if openDropdown != nil || saveToExpanded || enteringNewFolderName {
                Button("Close") { closeDropdown() }
                    .keyboardShortcut(.cancelAction)
                    .opacity(0).frame(width: 0, height: 0)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .disabled(model.busy)
        .animation(Motion.state(reduceMotion), value: enteringNewFolderName)
    }

    private var folderTitle: String {
        model.selectedLecture == "__new__" ? (model.newLecture.isEmpty ? "New folder" : model.newLecture) : model.selectedLecture
    }

    private var saveToControl: some View {
        Button(action: toggleSaveToWheel) {
            HStack(spacing: 5) {
                // The open wheel is the close control: its folder turns into an x.
                Image(systemName: saveToExpanded ? "xmark" : "folder")
                    .font(.system(size: saveToExpanded ? 11 : 10, weight: saveToExpanded ? .semibold : .medium))
                    .foregroundStyle(saveToExpanded ? Theme.accentText : Theme.muted)
                    .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
                    .rotationEffect(.degrees(saveToExpanded && !reduceMotion ? -360 : 0))
                    .accessibilityHidden(true)
                if !saveToExpanded {
                    Text(folderTitle).font(Theme.text(10.5, .medium)).foregroundStyle(Theme.ink)
                        .lineLimit(1).truncationMode(.middle).layoutPriority(-1).monospacedDigit()
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.85)))
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(Theme.muted)
                        .accessibilityHidden(true)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, saveToExpanded ? 0 : 8)
            .frame(width: saveToExpanded ? 34 : nil, height: 34)
            .frame(maxWidth: saveToExpanded ? nil : .infinity)
            // One rounded shape for pill and wheel: stroked capsules drew stray end caps beside the pill.
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 17, style: .circular))
            .overlay {
                RoundedRectangle(cornerRadius: 17, style: .circular)
                    .strokeBorder(saveToExpanded ? Theme.accentText.opacity(0.72) : Theme.line,
                                  lineWidth: saveToExpanded ? 1.2 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 17, style: .circular))
        }
        .focusEffectDisabled()
        .buttonStyle(CompactControlButtonStyle())
        .tip(saveToExpanded ? "Close" : "Save to folder")
        .accessibilityLabel(saveToExpanded ? "Close folder choices" : "Save to \(folderTitle)")
        .accessibilityHint(saveToExpanded ? "Returns to Session and Vocabulary" : "Open folder choices")
        .interactionTarget("dropdown-saveTo")
        .interactionTarget(saveToExpanded ? "save-to-wheel" : "save-to-button")
    }

    private var folderListOpen: Bool { openDropdown == .folders }

    // The space the folder pill frees: one capsule with Pick folder and a warm Choose destination.
    private var folderChoices: some View {
        HStack(spacing: 0) {
            Button(action: toggleFolderList) {
                HStack(spacing: 6) {
                    ViewThatFits(in: .horizontal) {
                        Text("Pick folder").font(Theme.text(10.5, .medium)).lineLimit(1).fixedSize()
                        Text("Folder").font(Theme.text(10.5, .medium)).lineLimit(1).fixedSize()
                    }
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                        .rotationEffect(.degrees(folderListOpen && !reduceMotion ? 180 : 0))
                        .accessibilityHidden(true)
                }
                .foregroundStyle(folderListOpen ? Theme.accentText : Theme.ink)
                .frame(maxWidth: .infinity).frame(height: 34)
                .contentShape(Rectangle())
            }
            .buttonStyle(CompactControlButtonStyle())
            .accessibilityHint(folderListOpen ? "Hide folders" : "Show folders")
            .interactionTarget("save-to-pick")
            Rectangle().fill(Theme.line).frame(width: 1, height: 16)
            Button(action: chooseTranscriptDestination) {
                HStack(spacing: 5) {
                    Image(systemName: "externaldrive").font(.system(size: 10, weight: .medium))
                        .accessibilityHidden(true)
                    ViewThatFits(in: .horizontal) {
                        Text("Choose destination").font(Theme.text(10.5, .semibold)).lineLimit(1).fixedSize()
                        Text("Destination").font(Theme.text(10.5, .semibold)).lineLimit(1).fixedSize()
                    }
                }
                .foregroundStyle(Theme.warmText)
                .padding(.horizontal, 10).frame(height: 28)
                .background(Theme.warmFill, in: Capsule())
                .padding(.horizontal, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(CompactControlButtonStyle())
            .disabled(model.working)
            .tip("Change where transcripts are saved")
            .accessibilityLabel("Choose destination")
            .interactionTarget("save-to-destination")
        }
        .frame(maxWidth: .infinity).frame(height: 34)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 17, style: .circular))
        .overlay(RoundedRectangle(cornerRadius: 17, style: .circular).strokeBorder(Theme.line, lineWidth: 1))
        .interactionTarget("save-to-group")
    }

    private var newFolderNameEntry: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.badge.plus").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.accentText)
                .accessibilityHidden(true)
            TextField("", text: $model.newLecture,
                      prompt: Text("Folder name").foregroundStyle(Theme.faint))
                .textFieldStyle(.plain).font(Theme.text(11)).foregroundStyle(Theme.ink)
                .focused($focus, equals: .lecture)
                .accessibilityLabel("New folder name")
                .interactionTarget("folder-name")
                .onSubmit(finishNewFolderName)
            Button(action: finishNewFolderName) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accentText)
            }
            .buttonStyle(ButtonActionStyle(tier: .icon, tint: Theme.accentText)).help("Done")
            .accessibilityLabel("Done")
            .interactionTarget("new-folder-done")
        }
        .padding(.horizontal, 10).frame(height: 36)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line, lineWidth: 1))
        .interactionTarget("new-folder-entry")
    }

    private func goHome() {
        guard !model.recording, !model.transitioning else { return }
        closeDropdown()
        if model.phase == .transcribing { model.homeFromTranscribing = true }
        else { model.phase = .idle }
    }

    private func requestSessionName() {
        sessionGate.request()
        startShake += 1
        suppressOutsideDismiss = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { suppressOutsideDismiss = false }
        if saveToExpanded || enteringNewFolderName { closeDropdown() }
        showDropdown(.session)
    }

    private var sessionIsEmpty: Bool {
        model.session.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var sessionControlTitle: String { sessionIsEmpty ? "Session name" : model.session }

    // One control per dropdown. With the wheel open it rolls into a bubble in place: the same
    // button resizes and moves, so the spring carries it to its compact spot instead of swapping views.
    private func controlButton(_ control: Dropdown, icon: String, value: String,
                               truncation: Text.TruncationMode, placeholder: Bool = false,
                               minWidth: CGFloat? = nil) -> some View {
        let compact = saveToExpanded
        let warn = control == .session && sessionIsEmpty
        return Button { toggleDropdown(control) } label: {
            HStack(spacing: compact ? 0 : 5) {
                Image(systemName: icon).font(.system(size: compact ? 11 : 10, weight: .medium))
                    .foregroundStyle(warn ? Theme.validationText : Theme.muted)
                    .accessibilityHidden(true)
                if !compact {
                    Text(value).font(Theme.text(10.5, .medium)).foregroundStyle(placeholder ? Theme.muted : Theme.ink)
                        .lineLimit(1).truncationMode(truncation).layoutPriority(placeholder ? 0 : -1).monospacedDigit()
                        .transition(.opacity)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(Theme.muted)
                        .accessibilityHidden(true)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, compact ? 0 : 8)
            .frame(width: compact ? 34 : nil, height: 34)
            .frame(minWidth: compact ? nil : minWidth, maxWidth: compact ? nil : .infinity)
            .background(warn ? Theme.validationFill : Theme.raised, in: Capsule())
            .overlay(RoundedRectangle(cornerRadius: 17, style: .circular)
                .strokeBorder(warn ? Theme.validationBorder :
                              (openDropdown == control ? Theme.accentText.opacity(0.72) : Theme.line),
                              lineWidth: warn ? 1.2 : (openDropdown == control ? 1.2 : 1)))
            .contentShape(Capsule())
        }
        .focusEffectDisabled()
        .buttonStyle(CompactControlButtonStyle())
        .if(compact) { $0.tip(control == .session ? "Session" : "Vocabulary") }
        .accessibilityLabel(compact ? control.accessibilityTitle
                            : (control == .session && placeholder ? "Session name" : "\(control.accessibilityTitle): \(value)"))
        .accessibilityHint(compact ? "Closes folder choices and opens \(control.accessibilityTitle.lowercased()) controls"
                           : "Opens \(control.accessibilityTitle.lowercased()) controls")
        .interactionTarget(compact ? "wheel-\(control)" : "dropdown-\(control)")
    }

    @ViewBuilder private func dropdownContent(_ control: Dropdown) -> some View {
        switch control {
        case .folders:
            VStack(spacing: 2) {
                if !model.lectures.isEmpty {
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(model.lectures, id: \.self) { lecture in
                                HStack(spacing: 4) {
                                    Button { chooseFolder(lecture) } label: {
                                        HStack(spacing: 8) {
                                            if model.selectedLecture == lecture {
                                                Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.accentText).frame(width: 14)
                                            } else {
                                                Color.clear.frame(width: 14, height: 10)
                                            }
                                            Text(lecture).font(Theme.text(11)).foregroundStyle(Theme.ink)
                                                .lineLimit(1).truncationMode(.middle)
                                            Spacer(minLength: 0)
                                        }
                                        .padding(.horizontal, 8).frame(height: 28)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(InsetButtonStyle())
                                    .accessibilityLabel("Save to \(lecture)")
                                    .interactionTarget("folder-\(lecture)")
                                    deleteFolderButton(lecture)
                                }
                                .onHover { inside in
                                    if inside { hoveredFolder = lecture } else if hoveredFolder == lecture { hoveredFolder = nil }
                                }
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(height: min(CGFloat(model.lectures.count) * 30 - 2, 128))
                    Rectangle().fill(Theme.line).frame(height: 1).padding(.vertical, 3)
                }
                Button(action: beginNewFolderName) {
                    HStack(spacing: 8) {
                        Image(systemName: "plus").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.accentText).frame(width: 14)
                        Text("New folder…").font(Theme.text(11)).foregroundStyle(Theme.ink)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8).frame(height: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(InsetButtonStyle())
                .interactionTarget("new-folder")
            }
            .padding(8)
            .card(Theme.surface, radius: 12)
            .accessibilityElement(children: .contain)
            .interactionTarget("save-to-folders")
        case .session:
            VStack(alignment: .leading, spacing: 7) {
                if sessionGate.required {
                    // Above the field: the message sits where the cursor is about to type.
                    Text(SessionNameGate.message)
                        .font(Theme.text(10.5, .medium))
                        .foregroundStyle(Theme.validationText)
                        .lineLimit(1)
                        .transition(.opacity)
                        .interactionTarget("session-required-message")
                }
                HStack(spacing: 9) {
                    TextField("", text: $model.session,
                              prompt: Text("Session name").foregroundStyle(Theme.faint))
                        .textFieldStyle(.plain).font(Theme.text(12)).foregroundStyle(Theme.ink)
                        .focused($focus, equals: .session)
                        .padding(.horizontal, 9).frame(height: 34)
                        .background(sessionGate.required ? Theme.validationFill : Theme.raised,
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(sessionGate.required ? Theme.validationBorder :
                                          (focus == .session ? Theme.accentText : Theme.line),
                                          lineWidth: sessionGate.required || focus == .session ? 1.4 : 1))
                        .background(SessionCaretPositioner(focused: focus == .session))
                        .accessibilityLabel("Session name")
                        .interactionTarget("session-name")
                        .onSubmit { closeDropdown() }
                    Button { model.session = AppModel.today } label: {
                        Image(systemName: "calendar").font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(IconButtonStyle(size: 34, filled: true))
                    .tip("Use today's date")
                    .accessibilityLabel("Use today's date")
                    .interactionTarget("session-today")
                }
            }
            .padding(10).card(Theme.surface, radius: 12)
            .animation(Motion.hover, value: sessionGate.required)
        case .vocabulary:
            if let vocabularyDraft {
                VocabularyEditor(draft: vocabularyDraft, close: { closeDropdown() }, inline: true,
                                 expanded: previewVocabularyExpanded)
                    .card(Theme.surface, radius: 12)
            } else {
                // No folder name yet: the panel still opens and says what to do next.
                Text("Name the folder first to add vocabulary")
                    .font(Theme.text(10.5, .medium)).foregroundStyle(Theme.muted)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10).card(Theme.surface, radius: 12)
                    .interactionTarget("vocabulary-needs-folder")
            }
        case .microphone:
            // The microphone panel sits above the controls row, so it is drawn there.
            EmptyView()
        }
    }

    private func toggleDropdown(_ control: Dropdown) {
        if saveToExpanded || enteringNewFolderName { closeDropdown() }
        if openDropdown == control { closeDropdown() }
        else { showDropdown(control) }
    }

    // Panels slide from their button on the same spring the wheel uses, and roll back the same way.
    private func showDropdown(_ control: Dropdown) {
        if openDropdown == .vocabulary { vocabularyDraft?.flush() }
        if control == .vocabulary { prepareVocabularyDraft() }
        // Previews keep their fixture devices; the real device list never leaks into a snapshot.
        if control == .microphone && !Snapshot.isRunning { model.refreshInputs() }
        withAnimation(Motion.state(reduceMotion)) { openDropdown = control }
        switch control {
        case .session: focus = .session
        case .vocabulary, .folders, .microphone: focus = nil
        }
    }

    // Every dismissal (outside tap, Escape, a choice, the wheel again) animates the open panel and the wheel out together.
    private func closeDropdown() {
        if openDropdown == .vocabulary { vocabularyDraft?.flush() }
        withAnimation(Motion.state(reduceMotion)) {
            openDropdown = nil
            saveToExpanded = false
            enteringNewFolderName = false
        }
        hoveredFolder = nil
        focus = nil
    }

    private func toggleSaveToWheel() {
        let wasOpen = saveToExpanded
        closeDropdown()
        guard !wasOpen else { return }
        model.refreshLectures()
        withAnimation(Motion.state(reduceMotion)) { saveToExpanded = true }
    }

    private func toggleFolderList() {
        focus = nil
        hoveredFolder = nil
        if folderListOpen {
            withAnimation(Motion.state(reduceMotion)) { openDropdown = nil }
        } else {
            model.refreshLectures()
            withAnimation(Motion.state(reduceMotion)) { openDropdown = .folders }
        }
    }

    private func chooseFolder(_ lecture: String) {
        model.selectedLecture = lecture
        closeDropdown()
    }

    // Each folder row shows a trash button on hover. Nothing moves until the owner confirms.
    private func deleteFolderButton(_ lecture: String) -> some View {
        let shown = (hoveredFolder ?? previewHoveredFolder) == lecture
        return Button { confirmTrashFolder(lecture) } label: {
            Image(systemName: "trash").font(.system(size: 10, weight: .medium))
                .accessibilityHidden(true)
        }
        .buttonStyle(IconButtonStyle(size: 24, destructive: true))
        .opacity(shown ? 1 : 0)
        .allowsHitTesting(shown)
        .animation(Motion.hover, value: shown)
        .tip("Delete folder")
        .accessibilityLabel("Delete folder \(lecture)")
        .interactionTarget("folder-delete-\(lecture)")
    }

    private func confirmTrashFolder(_ lecture: String) {
        guard model.finishLibraryEditing?() ?? true, LectureFolderTrash.confirm(lecture) else { return }
        if let url = model.vocabularyURL(for: lecture) { vocabularyDrafts[url] = nil }
        model.trashLecture(lecture, paths: model.paths)
        hoveredFolder = nil
    }

    private func beginNewFolderName() {
        model.selectedLecture = "__new__"
        model.newLecture = ""
        withAnimation(Motion.state(reduceMotion)) {
            openDropdown = nil
            saveToExpanded = false
            enteringNewFolderName = true
        }
        focus = .lecture
    }

    private func finishNewFolderName() {
        guard !model.newLecture.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        withAnimation(Motion.state(reduceMotion)) { enteringNewFolderName = false }
        focus = nil
    }

    private func chooseTranscriptDestination() {
        closeDropdown()
        _ = model.chooseTranscriptsFolder()
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

    // The microphone panel and the controls row share one hit region, so the mic button can
    // toggle its own panel without the outside-tap dismissal closing it first.
    @ViewBuilder private var controls: some View {
        VStack(spacing: 10) {
            if openDropdown == .microphone {
                microphonePanel
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
            // Recording adds Pause, so the row tightens to stay inside the 20pt margins.
            HStack(spacing: model.recording ? 8 : 10) {
                if model.recording {
                    Button { model.togglePause() } label: {
                        Text(model.paused ? "Resume" : "Pause").lineLimit(1).fixedSize()
                    }
                    .buttonStyle(PillButtonStyle(kind: .quiet, height: 46, horizontalPadding: 10))
                    .frame(width: 84)
                    .keyboardShortcut("p", modifiers: .command)
                    .tip(model.paused ? "Resume recording" : "Pause recording", edge: .top)
                    .accessibilityLabel(model.paused ? "Resume recording" : "Pause recording")
                    .disabled(model.transitioning)
                    .transition(.soft(reduceMotion))
                }
                micButton
                primaryButton
                libraryButton
            }
        }
        .background(GeometryReader { geometry in
            Color.clear.preference(key: DropdownRegionKey.self, value: [geometry.frame(in: .named(Self.space))])
        })
    }

    // Start stays fully lit. With no session name it turns red and asks for one instead.
    private var primaryButton: some View {
        Button(action: primaryAction) {
            if showsHomeAction {
                Label("Home", systemImage: "house")
                    .labelStyle(.titleAndIcon)
            } else {
                HStack(spacing: 10) {
                    Text(primaryTitle).lineLimit(1).fixedSize()
                    if showsCommandR {
                        Text("⌘R").font(Theme.text(11, .medium)).monospacedDigit().opacity(0.6)
                    }
                }
            }
        }
        .buttonStyle(primaryButtonStyle)
        .overlay {
            if sessionGate.required && !model.recording && !showsHomeAction {
                RoundedRectangle(cornerRadius: 23, style: .circular)
                    .strokeBorder(Theme.validationBorder, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .animation(Motion.hover, value: sessionGate.required)
        // Return starts; stopping takes ⌘Return so a stray keypress cannot end a lecture.
        .keyboardShortcut(model.recording
            ? KeyboardShortcut(.return, modifiers: .command)
            : ((model.phase == .idle || model.homeFromTranscribing) ? KeyboardShortcut(.return) : nil))
        .tip(showsHomeAction ? "Return home" : (model.recording ? "Stop and transcribe" : "Start recording"))
        .accessibilityLabel(showsHomeAction ? "Home" : primaryTitle)
        .interactionTarget("primary-action")
        .modifier(StartShake(animatableData: reduceMotion ? 0 : CGFloat(startShake)))
        .animation(reduceMotion ? .easeOut(duration: 0.18) : .easeOut(duration: 0.4), value: startShake)
        .disabled(model.recording ? model.transitioning : (!showsHomeAction && !model.hasLecture))
    }

    private var micButton: some View {
        Button { toggleDropdown(.microphone) } label: {
            Image(systemName: model.inputUID == nil || Snapshot.isRunning ? "mic" : "mic.fill")
        }
        .buttonStyle(IconButtonStyle(size: 44,
                                     active: (model.inputUID != nil && !Snapshot.isRunning) || openDropdown == .microphone,
                                     filled: true))
        .onHover { if $0 && !Snapshot.isRunning { model.refreshInputs() } }
        .tip("Microphone", edge: .top)
        .accessibilityLabel("Change recording source or microphone")
        .accessibilityValue(model.inputName)
        .accessibilityHint("Opens microphone and level controls")
        .interactionTarget("mic-button")
    }

    // Input device, recording source and a live level, in the card style of the other panels.
    private var microphonePanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            FieldLabel("Microphone").padding(.horizontal, 8).padding(.top, 2)
            Text(model.recordingSource.usesMic ? "In use: \(model.microphoneName)" : "Selected: \(model.microphoneName)")
                .font(Theme.text(10.5)).foregroundStyle(Theme.muted)
                .padding(.horizontal, 8).padding(.bottom, 2)
            micRow(model.systemInput.map { "System default (\($0.name))" } ?? "System default",
                   chosen: model.inputUID == nil, device: true) { model.selectInput(nil) }
            ForEach(model.inputs) { device in
                micRow(device.name, chosen: model.inputUID == device.id, device: true) { model.selectInput(device.id) }
            }
            if RecordingSource.macAudioAvailable {
                FieldLabel("Source").padding(.horizontal, 8).padding(.top, 6)
                micRow("Room audio · Microphone", chosen: model.recordingSource == .mic) { model.selectSource(.mic) }
                micRow("Mac audio · Mac audio + mic", chosen: model.recordingSource == .both) { model.selectSource(.both) }
                micRow("Mac audio only", chosen: model.recordingSource == .macAudio) { model.selectSource(.macAudio) }
            }
            Rectangle().fill(Theme.line).frame(height: 1).padding(.vertical, 4)
            HStack(spacing: 10) {
                Text("Level").font(Theme.text(11)).foregroundStyle(Theme.muted)
                if telemetryVisible {
                    LiveLevelBar(telemetry: model.telemetry)
                    LiveLevelReadout(telemetry: model.telemetry)
                } else {
                    LevelBar(level: model.telemetry.level)
                    FrozenLevelReadout(level: model.telemetry.level)
                }
            }
            .padding(.horizontal, 8)
            RecordingLevelGuidanceView(recording: model.recording, guidance: model.levelGuidance)
            Text("The level reads live while you record.")
                .font(Theme.text(10.5)).foregroundStyle(Theme.muted)
                .padding(.horizontal, 8).padding(.top, 2)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(Theme.surface, radius: 12)
        .interactionTarget("microphone-panel")
    }

    // Device selection remains locked during active capture; sources can change while recording.
    private func micRow(_ title: String, chosen: Bool, device: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            action()
            closeDropdown()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.accentText).frame(width: 14)
                    .opacity(chosen ? 1 : 0)
                Text(title).font(Theme.text(11)).foregroundStyle(Theme.ink)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(InsetButtonStyle())
        .disabled(model.micLocked || (device && model.recording && !model.paused))
        .accessibilityLabel(title)
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .interactionTarget("mic-\(title)")
    }

    // Browse the Library without interrupting capture.
    private var libraryButton: some View {
        Button {
            closeDropdown()
            if let onBrowse { onBrowse() } else { model.showInLibrary(nil) }
        } label: {
            if model.recording {
                Image(systemName: "books.vertical")
            } else {
                Label("Library", systemImage: "books.vertical")
            }
        }
        .buttonStyle(LibraryPillStyle(compact: model.recording))
        .tip("All your transcripts", edge: .top)
        .accessibilityLabel("Library")
        .accessibilityHint("Opens Library inside Nosy")
        .interactionTarget("browse-transcripts")
    }

    private func primaryAction() {
        focus = nil
        if showsHomeAction { goHome() }
        else if model.recording { model.stop() }
        else { model.start() }
    }
    private var showsHomeAction: Bool { model.phase == .done || model.phase == .failed }
    private var primaryButtonStyle: AnyButtonStyle {
        if model.recording {
            return AnyButtonStyle(PillButtonStyle(kind: .dark, height: 46, horizontalPadding: 14))
        }
        if showsHomeAction {
            return AnyButtonStyle(PillButtonStyle(kind: .primary, height: 46, horizontalPadding: 16))
        }
        return AnyButtonStyle(StartButtonStyle())
    }
    private var showsCommandR: Bool { model.phase == .idle || model.homeFromTranscribing }
    private var primaryTitle: String {
        if model.recording { return "Stop & transcribe" }
        switch model.phase {
        case .done, .failed: return "Home"
        default: return "Start recording"
        }
    }
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

struct NosyMark: View {
    var size: CGFloat
    private static let image = Bundle.main.image(forResource: "NosyMark") ?? NSApp?.applicationIconImage ?? NSImage()
    var body: some View {
        Image(nsImage: Self.image).resizable().interpolation(.high)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.32, style: .continuous))
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
    @State private var tintedSelection: RecordingSource = .mic
    private var selected: RecordingSource? {
        model.recordingSource == .mic ? .mic : .both
    }
    var body: some View {
        HStack(spacing: 3) {
            modeButton(RecordingSource.mic.modeTitle, source: .mic, active: selected == .mic)
            if RecordingSource.macAudioAvailable {
                modeButton(RecordingSource.both.modeTitle, source: .both, active: selected == .both)
            }
        }
        .padding(3)
        .background(Theme.surface.opacity(0.68), in: Capsule())
        .overlay(RoundedRectangle(cornerRadius: 17, style: .circular).strokeBorder(Theme.line, lineWidth: 1))
        .disabled(model.micLocked)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recording mode")
        .onAppear { tintedSelection = selected ?? .mic }
        .onChange(of: selected) { _, target in
            guard let target else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                guard selected == target else { return }
                withAnimation(reduceMotion ? .easeOut(duration: 0.18) : .easeOut(duration: 0.14)) {
                    tintedSelection = target
                }
            }
        }
    }
    private func modeButton(_ title: String, source: RecordingSource, active: Bool) -> some View {
        Button { select(source) } label: {
            ZStack {
                if active {
                    Capsule()
                        .fill(tintedSelection == .mic ? Theme.roomModeTint : Theme.macModeTint)
                        .if(!reduceMotion) { highlight in
                            highlight
                                .matchedGeometryEffect(id: "capture-mode-selection", in: selectionNamespace)
                        }
                        .if(reduceMotion) { highlight in highlight.transition(.opacity) }
                }
                Text(title).font(Theme.text(11, .medium))
                    .foregroundStyle(tintedSelection == source ? Theme.ink : Theme.muted)
                    .frame(maxWidth: .infinity).frame(height: 28)
            }
        }
        .focusEffectDisabled()
        .buttonStyle(ModePickerButtonStyle())
        .accessibilityAddTraits(active ? .isSelected : [])
        .interactionTarget("mode-\(source)")
    }

    private func select(_ source: RecordingSource) {
        // Compare the real source: "Mac audio only" shows as the Mac audio category but still needs choosing.
        guard model.recordingSource != source else { return }
        withAnimation(reduceMotion ? .easeOut(duration: 0.18) : .easeInOut(duration: 0.22)) {
            model.selectSource(source)
        }
    }
}

private extension View {
    @ViewBuilder func `if`<Transformed: View>(_ condition: Bool,
                                               transform: (Self) -> Transformed) -> some View {
        if condition { transform(self) } else { self }
    }
}

struct TitlebarBrandButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Theme.accent, in: Capsule())
            .contentShape(Capsule())
            .modifier(ButtonChrome(tier: .secondary, tint: Theme.accent,
                                   pressed: configuration.isPressed, shape: .capsule))
    }
}

private struct StartShake: GeometryEffect {
    var animatableData: CGFloat
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: sin(animatableData * .pi * 8) * 5, y: 0))
    }
}

// A solid blue action that keeps the established Library color.
private struct LibraryPillStyle: ButtonStyle {
    // Icon only while recording: Pause, the microphone and Stop need the row's full width.
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        LibraryPillBody(configuration: configuration, compact: compact)
    }
    private struct LibraryPillBody: View {
        let configuration: ButtonStyleConfiguration
        let compact: Bool
        @Environment(\.isFocused) private var focused
        var body: some View {
            configuration.label
                .font(Theme.text(13, .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, compact ? 0 : 14)
                .frame(width: compact ? 46 : nil, height: 46)
                .fixedSize()
                .background(Capsule().fill(Theme.libraryBlue))
                .contentShape(Capsule())
                .overlay(RoundedRectangle(cornerRadius: 25, style: .circular).strokeBorder(focused ? Theme.accentText : .clear, lineWidth: 2).padding(-2).allowsHitTesting(false))
                .modifier(ButtonChrome(tier: .primary, tint: Theme.libraryBlue,
                                       pressed: configuration.isPressed, shape: .capsule))
        }
    }
}

private struct StartButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StartButtonBody(configuration: configuration)
    }

    private struct StartButtonBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var enabled
        @Environment(\.isFocused) private var focused

        var body: some View {
            configuration.label
                .font(Theme.text(13, .semibold))
                .foregroundStyle(Theme.onAccent)
                .padding(.horizontal, 17)
                .frame(height: 46)
                .background(Capsule().fill(Theme.green.opacity(enabled ? 1 : 0.58)))
                .contentShape(Capsule())
                .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(focused ? Theme.accentText : .clear, lineWidth: 2).padding(-3))
                .modifier(ButtonChrome(tier: .primary, tint: Theme.green,
                                       pressed: configuration.isPressed, shape: .capsule))
        }
    }
}

// Shows the recorder's latest level. It reads the shared telemetry, so it needs no timer of its own.
// Tapping it switches between the estimated sound level and the technical value. The choice is remembered.
struct LiveLevelReadout: View {
    @ObservedObject var telemetry: RecordingTelemetry
    var body: some View { LevelReadout(level: telemetry.level) }
}

struct FrozenLevelReadout: View {
    let level: Double
    var body: some View { LevelReadout(level: level) }
}

private struct LevelReadout: View {
    let level: Double
    @AppStorage(LevelDisplay.storageKey) private var savedDisplay = LevelDisplay.estimate.rawValue

    private var display: LevelDisplay { LevelDisplay.stored(savedDisplay) }

    var body: some View {
        Button {
            savedDisplay = display.toggled.rawValue
        } label: {
            HStack(spacing: 6) {
                Text(InputLevel.primary(level, display: display))
                    .font(Theme.text(12, .semibold)).monospacedDigit()
                    .foregroundStyle(Theme.muted)
                if display == .estimate {
                    let band = InputLevel.band(level)
                    Text(band.label)
                        .font(Theme.text(9.5, .semibold))
                        .foregroundStyle(band.tint)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(band.tint.opacity(0.14), in: Capsule())
                }
            }
            .lineLimit(1)
            .fixedSize()
            .contentShape(Rectangle())
        }
        .buttonStyle(ButtonActionStyle(tier: .secondary, tint: Theme.accentText))
        .tip(display == .estimate ? "Estimated sound level. Tap for the technical value." : "Level in dB below full scale. Tap for the estimate.")
        .accessibilityLabel("Input level")
        .accessibilityValue(spokenValue)
        .accessibilityHint("Switches between the estimated sound level and the technical value")
    }

    private var spokenValue: String {
        guard display == .estimate else { return InputLevel.technical(level) }
        return "\(InputLevel.estimate(level)) decibels, \(InputLevel.band(level).label)"
    }
}

private struct RecordingLevelGuidanceView: View {
    let recording: Bool
    @ObservedObject var guidance: RecordingGuidancePresentation

    var body: some View {
        if recording {
            VStack(alignment: .trailing, spacing: 2) {
                Text("Recommended 55 to 75 dB")
                    .font(Theme.text(9.5)).foregroundStyle(Theme.muted)
                Text(advice)
                    .font(Theme.text(10.5, .medium)).foregroundStyle(guidance.band.tint)
                    .lineLimit(1).minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.horizontal, 8)
            .padding(.top, 1)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(advice)
            .accessibilityValue("Recommended 55 to 75 decibels")
        }
    }

    private var advice: String {
        switch guidance.band {
        case .quiet: "Too quiet. Move closer to the speaker."
        case .good: "Good level"
        case .loud: "Too loud. Move back a little."
        }
    }

}

private extension InputLevel.Band {
    var tint: Color {
        switch self {
        case .quiet: Theme.accentText
        case .good: Theme.savedText
        case .loud: Theme.amber
        }
    }
}

private extension RecordingLevelGuidance.Band {
    var tint: Color {
        switch self {
        case .quiet: Theme.accentText
        case .good: Theme.savedText
        case .loud: Theme.amber
        }
    }
}

private struct LiveLevelBar: View {
    @ObservedObject var telemetry: RecordingTelemetry
    var body: some View { LevelBar(level: telemetry.level) }
}

private struct LevelBar: View {
    let level: Double
    var body: some View {
        Canvas { context, size in
            let range = RecordingLevelGuidance.recommendedRange
            let start = size.width * CGFloat(InputLevel.estimateFraction(range.lowerBound))
            let end = size.width * CGFloat(InputLevel.estimateFraction(range.upperBound))
            let radius = size.height / 2
            context.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: radius), with: .color(Theme.line))
            let width = size.width * CGFloat(InputLevel.fraction(level))
            context.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: width, height: size.height), cornerRadius: radius),
                         with: .color(Theme.accentText))
            context.fill(Path(roundedRect: CGRect(x: start, y: 0, width: max(0, end - start), height: size.height), cornerRadius: radius),
                         with: .color(Theme.savedText.opacity(0.36)))
        }
        .frame(height: 6)
        .accessibilityElement()
        .accessibilityLabel("Input level meter")
        .accessibilityValue(InputLevel.technical(level))
    }
}

private struct DropdownRegionKey: PreferenceKey {
    static let defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value.append(contentsOf: nextValue()) }
}

private struct ModePickerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Capsule())
            .modifier(ButtonChrome(tier: .secondary, tint: Theme.accent,
                                        pressed: configuration.isPressed, shape: .capsule))
    }
}

private struct CompactControlButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CompactControlBody(configuration: configuration)
    }
    private struct CompactControlBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var focused
        @State private var hovering = false
        var body: some View {
            configuration.label
                .contentShape(Capsule())
                .overlay(RoundedRectangle(cornerRadius: 19, style: .continuous)
                    .strokeBorder(focused ? Theme.accentText : .clear, lineWidth: 2).padding(-2).allowsHitTesting(false))
                .onHover { inside in withAnimation(Motion.hover) { hovering = inside } }
                .modifier(ButtonChrome(tier: .secondary, tint: Theme.accent,
                                            pressed: configuration.isPressed, shape: .capsule))
        }
    }
}

// The dot dims while the input is quiet. Only this leaf follows the level samples.
private struct RecordingDot: View {
    let telemetry: RecordingTelemetry
    let paused: Bool
    @State private var audible: Bool

    init(telemetry: RecordingTelemetry, paused: Bool) {
        self.telemetry = telemetry
        self.paused = paused
        _audible = State(initialValue: telemetry.level > -50)
    }

    var body: some View {
        Circle().fill(paused ? Theme.amber : Theme.coral).frame(width: 7, height: 7)
            .opacity(paused || audible ? 1 : 0.5)
            .onReceive(telemetry.$sample.map { $0.level > -50 }.removeDuplicates()) { audible = $0 }
    }
}

struct StatusPill: View {
    @ObservedObject var model: AppModel
    @ViewBuilder
    var body: some View {
        if let title {
            HStack(spacing: 6) {
                if model.recording {
                    RecordingDot(telemetry: model.telemetry, paused: model.paused)
                }
                Text(title).font(Theme.text(10, .medium)).foregroundStyle(tint)
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

struct RecordingModeBanner: View {
    @ObservedObject var model: AppModel
    let onChange: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.amber)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Recording on \(model.recordingSource.modeTitle)")
                    .font(Theme.text(11, .bold)).foregroundStyle(Theme.ink)
                Text(recordingModeDescription)
                    .font(Theme.text(10.5)).foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 4)
            Button("Change", action: onChange)
                .buttonStyle(LinkButtonStyle(tint: Theme.accentText))
                .disabled(model.transitioning)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .card(Theme.amber.opacity(0.12), radius: 12)
    }

    private var recordingModeDescription: String {
        switch model.recordingSource {
        case .both: "your Mac's sound and your mic"
        case .mic: "the sound around you through your mic"
        case .macAudio: "your Mac's sound, not your mic"
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
                Text(text).font(Theme.text(12.5, .medium)).monospacedDigit().foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
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
    var telemetryVisible = true
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
                    .font(Theme.text(12)).monospacedDigit().foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                if model.recordingSource == .both {
                    Text("Mac audio").font(Theme.text(9, .medium)).foregroundStyle(Theme.accentText)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    if telemetryVisible {
                        RecordingClock(telemetry: model.telemetry, paused: model.paused)
                    } else {
                        RecordingClockText(duration: model.telemetry.duration, paused: model.paused)
                    }
                }
                Spacer(minLength: 0)
                if telemetryVisible {
                    LiveLevelReadout(telemetry: model.telemetry)
                } else {
                    FrozenLevelReadout(level: model.telemetry.level)
                }
            }
            if telemetryVisible {
                LiveWaveform(telemetry: model.telemetry, paused: model.paused)
            } else {
                Waveform(levels: model.telemetry.levels, tint: Theme.wavePlayed, active: !model.paused)
                    .frame(height: 24).padding(.horizontal, 20).frame(height: 44)
                    .background(Theme.waveform, in: Capsule())
                    .accessibilityLabel("Live recording input")
                    .accessibilityValue(InputLevel.technical(model.telemetry.level))
            }
            RecordingMarkers(model: model)
            if let active = model.active {
                if telemetryVisible {
                    BackgroundTranscriptionNote(telemetry: model.telemetry, lecture: active.lecture, pauseReason: model.transcriptionPauseReason)
                } else {
                    BackgroundTranscriptionText(progress: model.transcriptionProgress, lecture: active.lecture,
                                                pauseReason: model.transcriptionPauseReason, live: false)
                }
            }
        }
    }

    private var transcribing: some View {
        VStack(alignment: .leading, spacing: 12) {
            if telemetryVisible {
                TranscriptionProgressBlock(model: model, telemetry: model.telemetry)
            } else {
                TranscriptionProgressContent(progress: model.transcriptionProgress, elapsed: model.transcriptionElapsed,
                                             waiting: model.waiting, pauseReason: model.transcriptionPauseReason,
                                             active: model.active, live: false)
            }
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
                        .font(Theme.text(11, .medium))
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
                                    Text(Core.timer(markers[index].t)).font(Theme.text(12)).monospacedDigit().foregroundStyle(Theme.muted)
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
                    .scrollIndicators(.hidden)
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
                        .font(Theme.text(11)).monospacedDigit().foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
                }
            }
            Text(statLine)
                .font(Theme.text(11)).monospacedDigit().foregroundStyle(Theme.ink)
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
        var values = [summary.duration.map { Core.timer($0) } ?? "No duration"]
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

// The large elapsed time. Only this text follows the recorder's length samples.
private struct RecordingClock: View {
    @ObservedObject var telemetry: RecordingTelemetry
    let paused: Bool
    var body: some View {
        RecordingClockText(duration: telemetry.duration, paused: paused)
    }
}

private struct RecordingClockText: View {
    let duration: TimeInterval
    let paused: Bool
    var body: some View {
        Text(Core.timer(duration))
            .font(Theme.text(44)).monospacedDigit().tracking(-1.32)
            .foregroundStyle(paused ? Theme.muted : Theme.navy)
            .contentTransition(.numericText())
            .accessibilityLabel("Recorded \(Core.timer(duration))")
    }
}

// The live input strip. Only this strip follows the level samples.
private struct LiveWaveform: View {
    @ObservedObject var telemetry: RecordingTelemetry
    let paused: Bool
    var body: some View {
        Waveform(levels: telemetry.levels, tint: Theme.wavePlayed, active: !paused)
            .frame(height: 24).padding(.horizontal, 20).frame(height: 44)
            .background(Theme.waveform, in: Capsule())
            .accessibilityLabel("Live recording input").accessibilityValue(InputLevel.technical(telemetry.level))
    }
}

// Background transcription beside a recording. Only its percentage follows the progress samples.
private struct BackgroundTranscriptionNote: View {
    @ObservedObject var telemetry: RecordingTelemetry
    let lecture: String
    let pauseReason: String?
    var body: some View {
        BackgroundTranscriptionText(progress: telemetry.transcriptionProgress, lecture: lecture, pauseReason: pauseReason)
    }
}

private struct BackgroundTranscriptionText: View {
    let progress: Double
    let lecture: String
    let pauseReason: String?
    var live = true
    var body: some View {
        HStack(spacing: 6) {
            if live { ProgressView().controlSize(.mini) }
            Text(pauseReason.map { "Paused. \($0)" } ?? "Also transcribing \(lecture) · \(Int((progress * 100).rounded()))%")
                .font(Theme.text(11, .medium)).foregroundStyle(Theme.muted).lineLimit(2)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading).card()
    }
}

// Progress and time left for the foreground transcription. Only this block follows the progress samples.
private struct TranscriptionProgressBlock: View {
    @ObservedObject var model: AppModel
    @ObservedObject var telemetry: RecordingTelemetry
    var body: some View {
        TranscriptionProgressContent(progress: telemetry.transcriptionProgress, elapsed: telemetry.transcriptionElapsed,
                                     waiting: model.waiting, pauseReason: model.transcriptionPauseReason, active: model.active)
    }
}

private struct TranscriptionProgressContent: View {
    let progress: Double
    let elapsed: TimeInterval
    let waiting: Bool
    let pauseReason: String?
    let active: SessionRecord?
    var live = true
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !waiting {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(Int((progress * 100).rounded()))%")
                        .font(Theme.text(13, .semibold)).monospacedDigit().foregroundStyle(Theme.ink)
                        .contentTransition(.numericText())
                    Spacer(minLength: 8)
                    ProgressTrack(value: progress, tint: Theme.stop)
                        .frame(width: 210)
                }
            } else if live {
                ProgressView().progressViewStyle(.linear).tint(Theme.stop)
            } else {
                ProgressTrack(value: 0, tint: Theme.stop)
            }
            Text(remainingText).font(Theme.text(12)).monospacedDigit().foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
        }
    }
    private var remainingText: String {
        if let reason = pauseReason { return "Paused. \(reason)" }
        if waiting {
            if let active { return "Starts when \(active.lecture) · \(active.session) finishes" }
            return "Waiting to start"
        }
        guard progress > 0.04, progress < 1 else { return "Getting started… \(Core.timer(elapsed)) elapsed" }
        let remaining = elapsed / progress * (1 - progress)
        let minutes = Int((remaining / 60).rounded(.up))
        return remaining < 60 ? "Less than a minute left" : "About \(minutes) min left"
    }
}

// Rolling recent input levels, newest at right. This is a meter, never live transcription.
struct Waveform: View {
    let levels: [Double]
    let tint: Color
    let active: Bool
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
    }
}

struct ProgressTrack: View {
    let value: Double
    let tint: Color
    var body: some View {
        Canvas { context, size in
            let bounds = CGRect(origin: .zero, size: size)
            context.fill(Path(roundedRect: bounds, cornerRadius: size.height / 2), with: .color(Theme.line))
            let fill = CGRect(x: 0, y: 0, width: max(8, size.width * min(1, max(0, value))), height: size.height)
            context.fill(Path(roundedRect: fill, cornerRadius: size.height / 2), with: .color(tint))
        }
        .frame(height: 8)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
    }
}

#if !NOSY_UI_TEST
@main
enum EntryPoint {
    @MainActor static func main() async {
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
