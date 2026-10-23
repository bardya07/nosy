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
        guard model.working else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = model.recording ? "A lecture is still recording. Quit anyway?" : "A lecture is still transcribing. Quit anyway?"
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
        Button("Transcripts") { openWindow(id: "library") }.keyboardShortcut("t", modifiers: .command)
        Button("Import Recording…") { model.importRecording() }
            .keyboardShortcut("i", modifiers: .command)
            .disabled(model.busy)
        Button("Open Transcripts Folder") { model.revealTranscriptsFolder() }
            .keyboardShortcut("o", modifiers: [.command, .shift])
        Divider()
        Button("Set Up Nosy…") { openWindow(id: "welcome") }
    }
}

struct MainView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focus: Field?
    @State private var dropping = false
    enum Field { case lecture, session }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header.zIndex(1)
            banners
            fields.zIndex(1)
            StagePanel(model: model, dropping: dropping)
                .dropDestination(for: URL.self) { urls, _ in
                    guard let url = urls.first, !model.busy else { return false }
                    model.importRecording(url)
                    return true
                } isTargeted: { dropping = $0 && !model.busy }
            controls
        }
        .padding(.horizontal, 20)
        .padding(.top, 34)
        .padding(.bottom, 20)
        .frame(width: 360)
        .fixedSize(horizontal: true, vertical: true)
        .background(Theme.background)
        .tint(Theme.accent)
        .animation(Motion.state(reduceMotion), value: model.phase)
        .animation(Motion.state(reduceMotion), value: model.paused)
        .animation(Motion.state(reduceMotion), value: model.selectedLecture == "__new__")
        .animation(Motion.state(reduceMotion), value: model.active?.id)
        .onAppear {
            model.openWindow = openWindow
            if model.needsOnboarding { openWindow(id: "welcome") }
        }
        .onChange(of: model.selectedLecture) { _, lecture in
            if lecture == "__new__" { focus = .lecture }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 9) {
            NosyMark(size: 30)
            Text("Nosy").font(Theme.display(26, .heavy)).foregroundStyle(Theme.ink)
            Spacer()
            HStack(spacing: 0) {
                Button { openWindow(id: "library") } label: { Image(systemName: "doc.text") }
                    .buttonStyle(IconButtonStyle(size: 28))
                    .tip("Transcripts  ⌘T")
                    .accessibilityLabel("Show transcripts")
                Button { model.chooseTranscriptsFolder() } label: { Image(systemName: "folder") }
                    .buttonStyle(IconButtonStyle(size: 28))
                    .tip("Saving to “\(model.paths.transcripts.lastPathComponent)” — click to change")
                    .accessibilityLabel("Choose where transcripts are saved, currently \(model.paths.transcripts.lastPathComponent)")
                    .disabled(model.working)
                MicMenu(model: model).disabled(model.micLocked)
            }
            StatusPill(model: model).fixedSize().layoutPriority(1)
        }
    }

    @ViewBuilder private var banners: some View {
        if let setup = model.setupMessage {
            Banner(symbol: "exclamationmark.triangle.fill", tint: Theme.amber, text: setup) {
                HStack(spacing: 14) {
                    Button("Set up…") { openWindow(id: "welcome") }.buttonStyle(LinkButtonStyle(tint: Theme.ink))
                    Button("Check again") { model.refreshDependencies() }.buttonStyle(LinkButtonStyle(tint: Theme.muted))
                }
            }.transition(.soft(reduceMotion))
        }
        if let record = model.recovery.first {
            Banner(symbol: "arrow.counterclockwise", tint: Theme.amber,
                   text: "Unfinished lecture: \(record.lecture) · \(record.session), \(Core.minutes(Core.audioDuration(id: record.id, paths: model.paths))) min"
                    + (model.recovery.count > 1 ? " (+\(model.recovery.count - 1) more)" : "")) {
                HStack(spacing: 14) {
                    Button("Transcribe now") { model.retry(record) }.buttonStyle(LinkButtonStyle(tint: Theme.ink))
                    Button("Later") { model.postponeRecovery() }.buttonStyle(LinkButtonStyle(tint: Theme.muted))
                        .tip("Stays in Transcripts › Unfinished")
                    Button("Delete…") { model.deleteRecording(record) }.buttonStyle(LinkButtonStyle(tint: Theme.coral))
                }.disabled(model.busy)
            }.transition(.soft(reduceMotion))
        }
        if model.phase != .failed, let error = model.errorMessage {
            Banner(symbol: "exclamationmark.circle.fill", tint: Theme.coral, text: error) {
                HStack(spacing: 14) {
                    if model.microphoneDenied {
                        Button("Open Microphone Settings") { model.openMicrophoneSettings() }.buttonStyle(LinkButtonStyle(tint: Theme.ink))
                    }
                    Button("Dismiss") { model.clearError() }.buttonStyle(LinkButtonStyle(tint: Theme.muted))
                }
            }
            .help(model.errorDetail ?? "")
            .transition(.soft(reduceMotion))
        }
        if let notice = model.sleepNotice {
            Banner(symbol: "moon.zzz.fill", tint: Theme.amber, text: notice) {
                Button("OK") { model.sleepNotice = nil }.buttonStyle(LinkButtonStyle(tint: Theme.muted))
            }.transition(.soft(reduceMotion))
        }
        if model.stalled {
            Banner(symbol: "waveform.slash", tint: Theme.coral, text: "Nosy isn't receiving any audio. Check that your microphone is connected.") { EmptyView() }
                .transition(.soft(reduceMotion))
        } else if model.silenceWarning {
            Banner(symbol: "mic.slash.fill", tint: Theme.coral, text: "Nosy can't hear anything. Check your microphone.") { EmptyView() }
                .transition(.soft(reduceMotion))
        }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    FieldLabel("Lecture")
                    Spacer()
                    VocabularyButton(model: model)
                }
                LecturePicker(model: model)
                if model.selectedLecture == "__new__" {
                    TextField("", text: $model.newLecture, prompt: Text("Name your lecture").foregroundStyle(Theme.faint))
                        .textFieldStyle(.plain)
                        .focused($focus, equals: .lecture)
                        .onSubmit { focus = .session }
                        .fieldChrome(focused: focus == .lecture)
                        .accessibilityLabel("New lecture name")
                        .transition(.soft(reduceMotion))
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel("Session")
                TextField("", text: Binding(get: { model.session }, set: { model.session = $0; model.sessionEdited = true }),
                          prompt: Text("Session").foregroundStyle(Theme.faint))
                    .textFieldStyle(.plain)
                    .focused($focus, equals: .session)
                    .onSubmit { focus = nil }
                    .fieldChrome(focused: focus == .session)
                    .accessibilityLabel("Session name")
            }
        }
        .disabled(model.busy)
        .opacity(model.busy ? 0.55 : 1)
    }

    @ViewBuilder private var controls: some View {
        HStack(spacing: 10) {
            if model.recording {
                Button { model.togglePause() } label: {
                    Image(systemName: model.paused ? "play.fill" : "pause.fill")
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(RoundButtonStyle(size: 48))
                .keyboardShortcut("p", modifiers: .command)
                .tip(model.paused ? "Resume  ⌘P" : "Pause  ⌘P", edge: .top)
                .accessibilityLabel(model.paused ? "Resume recording" : "Pause recording")
                .disabled(model.transitioning)
                .transition(.soft(reduceMotion))
            }
            Button(action: { model.recording ? model.stop() : model.start() }) {
                HStack(spacing: 8) {
                    Image(systemName: model.recording ? "stop.fill" : "record.circle")
                        .contentTransition(.symbolEffect(.replace))
                    Text(primaryTitle)
                }
            }
            .buttonStyle(PillButtonStyle(kind: model.recording ? .dark : .primary, height: 48))
            // Return starts; stopping a lecture takes ⌘Return so a stray keypress can't end it.
            .keyboardShortcut(.return, modifiers: model.recording ? .command : [])
            .tip(model.recording ? "Stop  ⌘↩" : (model.canStart ? "Start  ↩" : "Name the lecture first"), edge: .top)
            .disabled(model.recording ? model.transitioning : !model.canStart)
        }
    }
    private var primaryTitle: String {
        if model.recording { return "Stop & transcribe" }
        switch model.phase {
        case .transcribing, .done, .failed: return "Record another"
        default: return "Start recording"
        }
    }
}

struct NosyMark: View {
    var size: CGFloat
    private static let image = Bundle.main.image(forResource: "NosyMark") ?? NSApp?.applicationIconImage ?? NSImage()
    var body: some View {
        Image(nsImage: Self.image).resizable().interpolation(.high)
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
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

// Per-lecture vocabulary: names, acronyms and terms Nosy should expect (saved as vocab.txt).
private struct VocabularyButton: View {
    @ObservedObject var model: AppModel
    @State private var open = false
    @State private var text = ""
    @State private var lecture = ""
    @State private var subjects = SubjectSettings()
    @State private var settingsError: String?
    var body: some View {
        Button {
            lecture = model.lectureName
            text = model.vocabulary(for: lecture)
            do {
                if let url = model.vocabularyURL(for: lecture) { subjects = try SubjectSettings.load(folder: url.deletingLastPathComponent()) }
                settingsError = nil
            } catch { subjects = SubjectSettings(subject: "off"); settingsError = error.localizedDescription }
            open = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "character.book.closed")
                Text("Vocabulary")
            }
            .font(Theme.text(11, .semibold))
        }
        .buttonStyle(LinkButtonStyle(tint: Theme.muted))
        .disabled(model.lectureName.trimmingCharacters(in: .whitespaces).isEmpty)
        .tip("Terms Nosy should expect in this lecture", edge: .top)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(lecture) vocabulary").font(Theme.display(15, .bold)).foregroundStyle(Theme.ink)
                Picker("Subject", selection: $subjects.subject) {
                    Text("Auto").tag("auto")
                    Text("Custom vocabulary only").tag("off")
                    ForEach(SubjectCatalog.subjects) { Text($0.name).tag($0.id) }
                }
                if subjects.subject != "off" {
                    Picker("Also include", selection: $subjects.additionalSubject) {
                        Text("None").tag("")
                        ForEach(SubjectCatalog.subjects.filter { $0.id != subjects.subject }) { Text($0.name).tag($0.id) }
                    }
                }
                if let settingsError { Text(settingsError).font(Theme.text(11)).foregroundStyle(Theme.coral) }
                if subjects.subject == "auto" {
                    let names = SubjectCatalog.subjects.filter { subjects.resolved(course: lecture).contains($0.id) }.map(\.name)
                    Text(names.isEmpty ? "Choose a subject if your course name gives no clues." : names.joined(separator: " + ") + " · guessed from course name")
                        .font(Theme.text(11)).foregroundStyle(Theme.muted)
                }
                if subjects.resolved(course: lecture).contains("arts-social-sciences") {
                    Text("Built-in vocabulary coming later; your terms still work.").font(Theme.text(11)).foregroundStyle(Theme.muted)
                }
                Text("Subject terms are used by Smarter vocabulary (beta) in Settings.")
                    .font(Theme.text(11)).foregroundStyle(Theme.muted)
                if !Set(subjects.resolved(course: lecture)).isDisjoint(with: ["engineering", "health-medicine", "psychology"]) {
                    Text("Includes related STEM vocabulary; add specialist course terms below.").font(Theme.text(11)).foregroundStyle(Theme.muted)
                }
                Text("Names, acronyms and terms, separated by commas or new lines. Put your most useful terms first.")
                    .font(Theme.text(11.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                TextEditor(text: $text)
                    .font(Theme.text(13))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(height: 120)
                    .background(Theme.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line))
                HStack {
                    Spacer()
                    Button("Cancel") { open = false }.buttonStyle(PillButtonStyle(kind: .quiet, height: 30, fullWidth: false))
                        .keyboardShortcut(.cancelAction)
                    Button("Save") { if model.saveVocabulary(text, for: lecture, settings: subjects) { open = false } }
                        .buttonStyle(PillButtonStyle(kind: .primary, height: 30, fullWidth: false))
                        .keyboardShortcut("s", modifiers: .command)
                }
            }
            .padding(16)
            .frame(width: 340)
            .background(Theme.background)
            .tint(Theme.accent)
        }
    }
}

private struct MicMenu: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Menu {
            Button { model.selectInput(nil) } label: {
                checked(model.inputUID == nil, "System default" + (model.systemInput.map { " (\($0.name))" } ?? ""))
            }
            if !model.inputs.isEmpty { Divider() }
            ForEach(model.inputs) { device in
                Button { model.selectInput(device.id) } label: { checked(model.inputUID == device.id, device.name) }
            }
        } label: {
            Image(systemName: model.inputUID == nil ? "mic" : "mic.fill")
        }
        .menuStyle(.button)
        .buttonStyle(IconButtonStyle(size: 28, active: model.inputUID != nil))
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { if $0 { model.refreshInputs() } }
        .tip(model.recording && !model.paused ? "Mic: \(model.inputName) — pause to switch" : "Mic: \(model.inputName)")
        .accessibilityLabel("Choose microphone, currently \(model.inputName)")
    }
    @ViewBuilder private func checked(_ on: Bool, _ title: String) -> some View {
        if on { Label(title, systemImage: "checkmark") } else { Text(title) }
    }
}

private struct LecturePicker: View {
    @ObservedObject var model: AppModel
    @State private var hovering = false
    var body: some View {
        Menu {
            ForEach(model.lectures, id: \.self) { lecture in
                Button(lecture) { model.selectedLecture = lecture }
            }
            if !model.lectures.isEmpty { Divider() }
            Button("New lecture…") { model.selectedLecture = "__new__" }
        } label: {
            HStack {
                Text(model.selectedLecture == "__new__" ? "New lecture" : model.selectedLecture)
                    .foregroundStyle(model.selectedLecture == "__new__" ? Theme.muted : Theme.ink)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.muted)
            }
            .fieldChrome()
            .brightness(hovering ? -0.015 : 0)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .onHover { inside in
            if inside { model.refreshLectures() }
            withAnimation(Motion.hover) { hovering = inside }
        }
        .accessibilityLabel("Lecture")
        .accessibilityValue(model.selectedLecture == "__new__" ? "New lecture" : model.selectedLecture)
    }
}

private struct StatusPill: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(tint).frame(width: 7, height: 7)
                .opacity(model.recording && !model.paused ? (model.level > -50 ? 1 : 0.5) : 1)
            Text(title).font(Theme.text(11.5, .semibold)).foregroundStyle(Theme.ink)
                .contentTransition(.opacity)
        }
        .padding(.horizontal, 10).frame(height: 24)
        .background(tint.opacity(0.14), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status: \(title)")
    }
    private var title: String {
        switch model.phase {
        case .idle: "Ready"
        case .recording: model.paused ? "Paused" : "Recording"
        case .transcribing: model.transcriptionPauseReason != nil ? "Paused" : (model.waiting ? "Queued" : "Transcribing")
        case .done: "Saved"
        case .failed: "Attention"
        }
    }
    private var tint: Color {
        switch model.phase {
        case .idle: Theme.muted
        case .recording: model.paused ? Theme.amber : Theme.coral
        case .transcribing: Theme.amber
        case .done: Theme.green
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            switch model.phase {
            case .idle: idle.transition(.soft(reduceMotion))
            case .recording: recording.transition(.soft(reduceMotion))
            case .transcribing: transcribing.transition(.soft(reduceMotion))
            case .done: done.transition(.soft(reduceMotion))
            case .failed: failed.transition(.soft(reduceMotion))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 158)
        .card(dropping ? Theme.accent.opacity(0.12) : Theme.surface)
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(dropping ? Theme.accent : Theme.line.opacity(0.6), style: StrokeStyle(lineWidth: dropping ? 1.5 : 1, dash: dropping ? [5, 4] : [])))
        .animation(Motion.hover, value: dropping)
    }

    private var idle: some View {
        VStack(spacing: 10) {
            Waveform(levels: model.levels, tint: Theme.faint, active: false).frame(height: 34).padding(.horizontal, 22)
            Text(dropping ? "Drop to transcribe" : "Ready when you are").font(Theme.display(17, .bold)).foregroundStyle(Theme.ink)
            Text(model.canStart ? "Press Return to start · or drop an audio file here" : "Name your lecture to start")
                .font(Theme.text(12)).foregroundStyle(Theme.muted)
        }.padding(.vertical, 16)
    }

    private var recording: some View {
        VStack(spacing: 8) {
            Text(Core.timer(model.duration))
                .font(Theme.display(38, .bold)).monospacedDigit()
                .foregroundStyle(model.paused ? Theme.muted : Theme.ink)
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: Int(model.duration))
                .accessibilityLabel("Recorded \(Core.timer(model.duration))")
            Waveform(levels: model.levels, tint: model.paused ? Theme.faint : Theme.coral, active: !model.paused)
                .frame(height: 30).padding(.horizontal, 22)
                .accessibilityLabel("Microphone level").accessibilityValue("\(Int(model.level)) decibels")
            Text(recordingCaption)
                .font(Theme.text(12, .medium)).foregroundStyle(Theme.muted).lineLimit(1)
                .padding(.horizontal, 16)
            if let active = model.active {
                // An earlier lecture is still being written up in the background.
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(model.transcriptionPauseReason.map { "Paused — \($0)" } ?? "Also transcribing \(active.lecture) · \(Int((model.transcriptionProgress * 100).rounded()))%")
                        .font(Theme.text(11, .medium)).foregroundStyle(Theme.faint).lineLimit(1)
                }
            }
        }.padding(.vertical, 12)
    }
    private var recordingCaption: String {
        if model.paused { return "Paused · nothing is being recorded" }
        let mic = model.activeInputName.map { " · \($0)" } ?? ""
        return "\(model.current?.lecture ?? model.lectureName)\(mic)"
    }

    private var transcribing: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.waiting ? "In line" : "Writing it up").font(Theme.display(17, .bold)).foregroundStyle(Theme.ink)
                Spacer()
                if !model.waiting {
                    Text("\(Int((model.transcriptionProgress * 100).rounded()))%")
                        .font(Theme.text(13, .semibold)).monospacedDigit().foregroundStyle(Theme.ink)
                        .contentTransition(.numericText())
                }
            }
            ProgressTrack(value: model.waiting ? 0 : model.transcriptionProgress, tint: Theme.amber)
            Text(remainingText).font(Theme.text(12)).foregroundStyle(Theme.muted)
                .lineLimit(2)
                .contentTransition(.opacity)
            if let record = model.current {
                Text("\(record.lecture) · \(record.session) — you can start the next lecture now")
                    .font(Theme.text(11)).foregroundStyle(Theme.faint).lineLimit(1)
            }
        }
        .padding(18)
        .accessibilityElement(children: .combine)
    }
    private var remainingText: String {
        if let reason = model.transcriptionPauseReason { return "Paused — \(reason)" }
        if model.waiting, let active = model.active { return "Starts when \(active.lecture) · \(active.session) finishes" }
        guard let remaining = model.transcriptionRemaining else { return "Getting started… \(Core.timer(model.transcriptionElapsed)) elapsed" }
        let minutes = Int((remaining / 60).rounded(.up))
        return remaining < 60 ? "Less than a minute left" : "About \(minutes) min left"
    }

    private var done: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark").font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.onAccent)
                .frame(width: 38, height: 38).background(Theme.green, in: Circle())
                .accessibilityHidden(true)
            Text("Transcript saved").font(Theme.display(17, .bold)).foregroundStyle(Theme.ink)
            if let record = model.current {
                Text(savedCaption(record)).font(Theme.text(12, .medium)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            HStack(spacing: 16) {
                Button("Open") { model.showInLibrary(model.current?.transcriptPath.map { URL(fileURLWithPath: $0) }) }
                    .buttonStyle(LinkButtonStyle())
                Button("Show in Finder") { model.revealTranscript() }.buttonStyle(LinkButtonStyle())
            }
        }.padding(.vertical, 16).padding(.horizontal, 16)
    }
    // Mentions when the session name was taken and the file got a -2 suffix.
    private func savedCaption(_ record: SessionRecord) -> String {
        guard let path = record.transcriptPath else { return "\(record.lecture) · \(record.session)" }
        let saved = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        return saved == record.session ? "\(record.lecture) · \(record.session)" : "\(record.lecture) · saved as “\(saved)”"
    }

    private var failed: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark").font(.system(size: 17, weight: .heavy)).foregroundStyle(Theme.coral)
                .frame(width: 38, height: 38).background(Theme.coral.opacity(0.14), in: Circle())
                .accessibilityHidden(true)
            Text(model.errorMessage ?? "Something went wrong")
                .font(Theme.text(13, .medium)).foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .help(model.errorDetail ?? "")
                .textSelection(.enabled)
            HStack(spacing: 16) {
                if model.microphoneDenied {
                    Button("Open Microphone Settings") { model.openMicrophoneSettings() }.buttonStyle(LinkButtonStyle())
                }
                if let record = model.current {
                    Button("Retry") { model.retry() }.buttonStyle(LinkButtonStyle()).disabled(model.isQueued(record.id))
                }
            }
        }.padding(.vertical, 16).padding(.horizontal, 18)
    }
}

// Rolling bars of recent mic levels; the newest bar is on the right.
struct Waveform: View {
    let levels: [Double]
    let tint: Color
    let active: Bool
    var body: some View {
        Canvas { context, size in
            let count = levels.count
            let gap: CGFloat = 3
            let width = max(1.5, (size.width - gap * CGFloat(count - 1)) / CGFloat(count))
            for (index, db) in levels.enumerated() {
                let normalized = active ? min(1, max(0, (db + 55) / 50)) : 0
                let height = max(width, size.height * CGFloat(0.08 + 0.92 * normalized))
                let x = CGFloat(index) * (width + gap)
                let rect = CGRect(x: x, y: (size.height - height) / 2, width: width, height: height)
                // Older bars fade out toward the left.
                let age = Double(index) / Double(max(1, count - 1))
                context.fill(Path(roundedRect: rect, cornerRadius: width / 2), with: .color(tint.opacity(active ? 0.35 + 0.65 * age : 0.55)))
            }
        }
        .animation(.linear(duration: 0.1), value: levels)
        .accessibilityHidden(!active)
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
