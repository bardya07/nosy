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
        Button(model.phase == .done ? "Record Another" : "Start Recording") {
            if model.phase == .done { model.phase = .idle }
            else { model.start() }
        }
        .keyboardShortcut("r", modifiers: .command)
        .disabled(model.recording || model.transitioning || (model.phase != .done && !model.canStart))
        Divider()
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
        VStack(spacing: 0) {
            titlebar.zIndex(3)
            VStack(alignment: .leading, spacing: model.phase == .idle ? 18 : 16) {
                banners
                if model.phase == .idle { brand }
                if model.phase != .recording && model.phase != .done { fields.zIndex(2) }
                StagePanel(model: model, dropping: dropping)
                controls
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 20)
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first, !model.busy else { return false }
                model.importRecording(url)
                return true
            } isTargeted: { dropping = $0 && !model.busy }
        }
        .frame(width: 360)
        .fixedSize(horizontal: true, vertical: true)
        .background(WindowBackdrop())
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.panelBorder.opacity(0.78)).allowsHitTesting(false))
        .ignoresSafeArea(.container, edges: .top)
        .tint(Theme.accentText)
        .animation(Motion.state(reduceMotion), value: model.phase)
        .animation(Motion.state(reduceMotion), value: model.paused)
        .animation(Motion.state(reduceMotion), value: model.selectedLecture == "__new__")
        .animation(Motion.state(reduceMotion), value: model.active?.id)
        .onAppear {
            model.openWindow = openWindow
            if model.needsOnboarding && !Snapshot.isRunning { openWindow(id: "welcome") }
        }
        .onChange(of: model.selectedLecture) { _, lecture in
            if lecture == "__new__" { focus = .lecture }
        }
    }

    // Leave room for the native traffic lights, with the retained utility actions alongside status.
    private var titlebar: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 76)
            HStack(spacing: 0) {
                Button { openWindow(id: "library") } label: { Image(systemName: "doc.text") }
                    .buttonStyle(IconButtonStyle(size: 26))
                    .tip("Transcripts  ⌘T")
                    .accessibilityLabel("Show transcripts")
                Button { model.chooseTranscriptsFolder() } label: { Image(systemName: "folder") }
                    .buttonStyle(IconButtonStyle(size: 26))
                    .tip("Saving to “\(model.paths.transcripts.lastPathComponent)” — click to change")
                    .accessibilityLabel("Choose where transcripts are saved, currently \(model.paths.transcripts.lastPathComponent)")
                    .disabled(model.working)
                MicMenu(model: model).disabled(model.micLocked)
            }
            StatusPill(model: model).fixedSize().frame(minWidth: 50, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private var brand: some View {
        HStack(spacing: 12) {
            NosyMark(size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("Nosy").font(Theme.display(20, .bold)).tracking(-0.4).foregroundStyle(Theme.ink)
                Text("on-device").font(Theme.mono(11)).foregroundStyle(Theme.muted)
            }
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
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Course").font(Theme.text(13)).foregroundStyle(Theme.muted)
                Spacer(minLength: 4)
                LecturePicker(model: model)
            }
            .padding(.horizontal, 14).frame(height: 41)
            if model.selectedLecture == "__new__" {
                TextField("", text: $model.newLecture, prompt: Text("Name your course").foregroundStyle(Theme.faint))
                    .textFieldStyle(.plain)
                    .font(Theme.mono(13)).foregroundStyle(Theme.ink)
                    .focused($focus, equals: .lecture)
                    .onSubmit { focus = .session }
                    .padding(.horizontal, 14).padding(.bottom, 11)
                    .accessibilityLabel("New course name")
                    .transition(.soft(reduceMotion))
            }
            Rectangle().fill(Theme.line).frame(height: 1)
            HStack(spacing: 12) {
                Text("Session").font(Theme.text(13)).foregroundStyle(Theme.muted)
                TextField("", text: Binding(get: { model.session }, set: { model.session = $0; model.sessionEdited = true }),
                          prompt: Text("Session").foregroundStyle(Theme.faint))
                    .textFieldStyle(.plain)
                    .font(Theme.mono(13)).foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.trailing)
                    .focused($focus, equals: .session)
                    .onSubmit { focus = nil }
                    .accessibilityLabel("Session name")
            }
            .padding(.horizontal, 14).frame(height: 41)
            Rectangle().fill(Theme.line).frame(height: 1)
            VocabularyButton(model: model)
        }
        .card()
        .disabled(model.busy)
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
                .tip(model.paused ? "Resume  ⌘P" : "Pause  ⌘P", edge: .top)
                .accessibilityLabel(model.paused ? "Resume recording" : "Pause recording")
                .disabled(model.transitioning)
                .transition(.soft(reduceMotion))
            }
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
            .tip(model.recording ? "Stop  ⌘↩" : (model.canStart ? "\(primaryTitle)  ⌘R / ↩" : "Name the course first"), edge: .top)
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
            HStack {
                Text("Vocabulary").font(Theme.text(13)).foregroundStyle(Theme.muted)
                Spacer()
                Text("\(CourseVocabularySummary.terms(model.vocabulary(for: model.lectureName)).count) custom terms")
                    .font(Theme.mono(13)).foregroundStyle(Theme.ink)
            }
            .padding(.horizontal, 14).frame(height: 41)
            .contentShape(Rectangle())
        }
        .buttonStyle(InsetButtonStyle())
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
            .font(Theme.text(13))
            .foregroundStyle(Theme.ink)
            .padding(16)
            .frame(width: 340)
            .background(WindowBackdrop())
            .tint(Theme.accentText)
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
            Image(systemName: model.inputUID == nil || Snapshot.isRunning ? "mic" : "mic.fill")
        }
        .menuStyle(.button)
        .buttonStyle(IconButtonStyle(size: 28, active: model.inputUID != nil && !Snapshot.isRunning))
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
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.muted)
            }
            .font(Theme.mono(13))
            .brightness(hovering ? -0.06 : 0)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .onHover { inside in
            if inside { model.refreshLectures() }
            withAnimation(Motion.hover) { hovering = inside }
        }
        .accessibilityLabel("Course")
        .accessibilityValue(model.selectedLecture == "__new__" ? "New lecture" : model.selectedLecture)
    }
}

private struct StatusPill: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(spacing: 6) {
            if model.recording {
                Circle().fill(model.paused ? Theme.amber : Theme.coral).frame(width: 7, height: 7)
                    .opacity(model.paused || model.level > -50 ? 1 : 0.5)
            }
            Text(title).font(Theme.mono(11)).foregroundStyle(tint)
                .contentTransition(.opacity)
        }
        .frame(height: 24)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status: \(title)")
    }
    private var title: String {
        switch model.phase {
        case .idle: "idle"
        case .recording: model.paused ? "paused" : "REC"
        case .transcribing: model.transcriptionPauseReason != nil ? "Paused" : (model.waiting ? "Queued" : "Transcribing")
        case .done: "saved"
        case .failed: "Attention"
        }
    }
    private var tint: Color {
        switch model.phase {
        case .idle: Theme.muted
        case .recording: model.paused ? Theme.amber : Theme.recordingText
        case .transcribing: Theme.amber
        case .done: Theme.savedText
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
        Text("mic: \(Snapshot.isRunning ? "MacBook Pro" : model.inputName) · \(Snapshot.isRunning ? "\(Int(model.level))" : "—") dB")
            .font(Theme.mono(11)).foregroundStyle(Theme.muted)
            .lineLimit(1).truncationMode(.middle)
            .frame(maxWidth: .infinity)
            .help("Microphone: \(model.inputName). Input level appears while recording. Drop an audio file here to transcribe it.")
            .accessibilityLabel("Microphone: \(model.inputName). \(Snapshot.isRunning ? "\(Int(model.level)) decibels" : "Level available while recording")")
    }

    private var recording: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(model.current?.lecture ?? model.lectureName) · \(model.current?.session ?? model.session)")
                    .font(Theme.mono(12)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
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
                .accessibilityLabel("Live microphone input").accessibilityValue("\(Int(model.level)) decibels")
            HStack(spacing: 6) {
                Image(systemName: model.paused ? "pause.fill" : "mic.fill").font(.system(size: 10))
                Text(model.paused ? "Paused · nothing is being recorded" : "\(Snapshot.isRunning ? "MacBook Pro" : model.inputName) · \(Int(model.level)) dB")
                    .lineLimit(1).truncationMode(.middle)
            }
            .font(Theme.mono(11)).foregroundStyle(Theme.muted)
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
            HStack(alignment: .firstTextBaseline) {
                Text(model.waiting ? "In line" : "Writing it up").font(Theme.display(17, .bold)).foregroundStyle(Theme.ink)
                Spacer()
                if !model.waiting {
                    Text("\(Int((model.transcriptionProgress * 100).rounded()))%")
                        .font(Theme.text(13, .semibold)).monospacedDigit().foregroundStyle(Theme.ink)
                        .contentTransition(.numericText())
                }
            }
            ProgressTrack(value: model.waiting ? 0 : model.transcriptionProgress, tint: Theme.stop)
            Text(remainingText).font(Theme.text(12)).foregroundStyle(Theme.muted)
                .lineLimit(2)
                .contentTransition(.opacity)
            if let record = model.current {
                Text("\(record.lecture) · \(record.session) — you can start the next lecture now")
                    .font(Theme.text(11)).foregroundStyle(Theme.faint).lineLimit(1)
            }
        }
        .padding(14).card()
        .accessibilityElement(children: .combine)
    }
    private var remainingText: String {
        if let reason = model.transcriptionPauseReason { return "Paused — \(reason)" }
        if model.waiting {
            if let active = model.active { return "Starts when \(active.lecture) · \(active.session) finishes" }
            return "Waiting for transcription to begin…"
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
        }.padding(14).frame(maxWidth: .infinity).card()
    }
}

// UI-only count of custom terms; built-in subjects remain a separate opt-in aid.
enum CourseVocabularySummary {
    static func terms(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .flatMap { $0.components(separatedBy: ",") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
}

private struct SavedPanel: View {
    @ObservedObject var model: AppModel
    @State private var summary = SavedSummary()
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark").font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 40, height: 40).background(Theme.green, in: Circle()).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Transcript saved").font(Theme.display(20, .bold)).tracking(-0.4).foregroundStyle(Theme.ink)
                    Text("\(model.current?.lecture ?? model.lectureName) · \(savedSession)")
                        .font(Theme.mono(11)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
                }
            }
            VStack(spacing: 5) {
                stat("duration", summary.duration.map { Core.timer($0) } ?? "—")
                stat("words", summary.words.map { $0.formatted() } ?? "—")
                stat("vocab hits", summary.vocabHits.map { "\($0) / \(summary.terms)" } ?? "—")
                if let path = model.current?.transcriptPath {
                    Text("→ \(abbreviated(path))")
                        .font(Theme.mono(11)).foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(2).truncationMode(.middle).textSelection(.enabled).help(path)
                        .padding(.top, 3)
                }
            }
            .padding(.vertical, 12).padding(.horizontal, 14).card()
            HStack(spacing: 8) {
                Button("Open") { model.showInLibrary(model.current?.transcriptPath.map { URL(fileURLWithPath: $0) }) }
                    .tip("Open in Transcripts", edge: .top)
                Button("Reveal") { model.revealTranscript() }.tip("Show in Finder", edge: .top)
                Button(copied ? "Copied" : "Copy") {
                    guard let text = summary.markdown else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.4)); copied = false }
                }
                .disabled(summary.markdown == nil)
                .tip("Copy transcript", edge: .top)
            }
            .buttonStyle(PillButtonStyle(kind: .quiet, height: 38))
            .disabled(model.current?.transcriptPath == nil)
        }
        .task(id: model.current?.transcriptPath) {
            summary = SavedSummary(record: model.current, model: model)
        }
    }
    private var savedSession: String {
        model.current?.transcriptPath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
            ?? model.current?.session ?? model.session
    }
    private func stat(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(Theme.muted)
            Spacer()
            Text(value).foregroundStyle(Theme.ink)
        }.font(Theme.mono(12)).frame(minHeight: 18)
    }
    private func abbreviated(_ path: String) -> String {
        if let preview = Snapshot.displayPath(path) { return preview }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

// Read existing transcript/audio metadata for presentation; no sidecar or pipeline changes.
private struct SavedSummary {
    var markdown: String?
    var duration: TimeInterval?
    var words: Int?
    var terms = 0
    var vocabHits: Int?
    init() {}
    @MainActor init(record: SessionRecord?, model: AppModel) {
        guard let record else { return }
        let audioLength = Core.audioDuration(id: record.id, paths: model.paths)
        let elapsed = record.endedAt.map { $0.timeIntervalSince(record.startedAt) } ?? 0
        duration = audioLength > 0 ? audioLength : (model.duration > 0 ? model.duration : (elapsed > 0 ? elapsed : nil))
        let vocabulary = CourseVocabularySummary.terms(model.vocabulary(for: record.lecture))
        terms = vocabulary.count
        guard let path = record.transcriptPath, let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        markdown = text
        let spoken = text.components(separatedBy: "## Transcript").dropFirst().joined(separator: "## Transcript")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        words = spoken == "_No speech detected._" ? 0 : spoken.split(whereSeparator: { $0.isWhitespace }).count
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
