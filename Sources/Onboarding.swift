import SwiftUI
import AppKit
import AVFoundation

// First-run setup: microphone, save folder, speech engine + model, and a five-second
// rehearsal that runs the real pipeline so the first lecture isn't the first test.
@MainActor
final class OnboardingModel: ObservableObject {
    enum Step: Int, CaseIterable { case welcome, microphone, folder, engine, tryIt }
    enum Rehearsal: Equatable {
        case ready
        case recording(remaining: Int)
        case transcribing(Double)
        case done(String)
        case failed(String)
    }
    @Published var step: Step = .welcome
    @Published var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @Published var downloading = false
    @Published var cancelling = false
    @Published var downloadFraction = 0.0
    @Published var downloadDetail = ""
    @Published var downloadError: String?
    @Published var rehearsal: Rehearsal = .ready
    @Published var rehearsalLevel = -160.0
    private var download: ModelDownload?
    private var rehearsalTask: Task<Void, Never>?
    private var rehearsalJob: TranscriptionJob?
    var rehearsing: Bool {
        switch rehearsal { case .recording, .transcribing: true; default: false }
    }

    func requestMicrophone() async {
        if micStatus == .notDetermined { _ = await AVCaptureDevice.requestAccess(for: .audio) }
        micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    }
    func whisperReady(_ paths: AppPaths) -> Bool { paths.whisper != nil }
    func modelReady(_ paths: AppPaths) -> Bool { SpeechModel.validate(paths.model) }

    func startDownload(paths: AppPaths) {
        guard !downloading else { return }
        try? paths.prepareSupport()
        downloading = true
        downloadError = nil
        let download = self.download ?? ModelDownload(paths: paths)
        self.download = download
        download.start(progress: { [weak self] fraction, received, total in
            Task { @MainActor in
                guard let self else { return }
                self.downloadFraction = fraction
                let formatter = ByteCountFormatter()
                self.downloadDetail = "\(formatter.string(fromByteCount: received)) of \(formatter.string(fromByteCount: total > 0 ? total : SpeechModel.expectedBytes))"
            }
        }, completion: { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.downloading = false
                self.cancelling = false
                switch result {
                case .success: self.download = nil; self.downloadFraction = 1
                case .failure(let error as CancellationError): _ = error; self.downloadError = "Download paused."
                case .failure(let error): self.downloadError = error.localizedDescription
                }
                AppModel.shared.refreshDependencies()
            }
        })
    }
    // `downloading` clears when the completion arrives, after resume data is saved.
    func cancelDownload() {
        cancelling = true
        download?.cancel()
    }
    // For networks that block the download: pick a ggml-large-v3-turbo.bin fetched elsewhere.
    func useDownloadedModel(paths: AppPaths) {
        let panel = NSOpenPanel()
        panel.title = "Choose speech model file"
        panel.prompt = "Use This File"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        downloading = true
        downloadDetail = "Copying model…"
        Task {
            do {
                try await Task.detached {
                    try paths.prepareSupport()
                    try SpeechModel.install(from: url, paths: paths)
                }.value
                downloadError = nil
            } catch { downloadError = Core.friendlyError(error.localizedDescription) }
            downloading = false
            downloadDetail = ""
            AppModel.shared.refreshDependencies()
        }
    }

    func startRehearsal(paths: AppPaths, inputUID: String?) {
        guard rehearsalTask == nil, !AppModel.shared.busy else { return }
        rehearsalTask = Task { await rehearse(paths: paths, inputUID: inputUID); rehearsalTask = nil }
    }
    func cancelRehearsal() {
        rehearsalTask?.cancel()
        rehearsalJob?.cancel()
    }
    private func rehearse(paths: AppPaths, inputUID: String?) async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Nosy-rehearsal-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let practice = paths.rehearsal(in: folder)
        // Holding the main window's lock keeps a real lecture from starting alongside.
        AppModel.shared.transitioning = true
        defer { AppModel.shared.transitioning = false }
        var recorder: Recorder?
        let job = TranscriptionJob()
        rehearsalJob = job
        defer { rehearsalJob = nil }
        do {
            await requestMicrophone()
            guard micStatus == .authorized else { throw LectureError.message("Microphone access is off. Allow it in System Settings › Privacy & Security › Microphone.") }
            try practice.prepareSupport()
            try FileManager.default.createDirectory(at: practice.lectureFolder("Rehearsal"), withIntermediateDirectories: true)
            var record = SessionRecord(id: Core.newID(in: practice), lecture: "Rehearsal", session: "Try it", startedAt: Date(), status: .recording)
            try record.save(in: practice)
            let live = Recorder(inputUID: inputUID) { [weak self] event in
                if case .level(_, let db, _) = event { Task { @MainActor in self?.rehearsalLevel = db } }
            }
            recorder = live
            try await live.start(at: practice.audioFile(record.id, "pcm"))
            for remaining in stride(from: 5, through: 1, by: -1) {
                rehearsal = .recording(remaining: remaining)
                try await Task.sleep(for: .seconds(1))
            }
            _ = try await live.stop()
            recorder = nil
            record.endedAt = Date()
            rehearsal = .transcribing(0)
            let result = try await Transcriber.transcribe(record: record, paths: practice, job: job) { [weak self] value in
                Task { @MainActor in
                    if case .transcribing = self?.rehearsal { self?.rehearsal = .transcribing(value) }
                }
            }
            let markdown = result.transcriptPath.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? ""
            let spoken = markdown.components(separatedBy: "## Transcript").last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            rehearsal = .done(spoken.isEmpty || spoken.contains("No speech detected") ? "" : spoken)
        } catch {
            _ = try? await recorder?.stop()
            rehearsal = Task.isCancelled || error is CancellationError ? .ready : .failed(Core.friendlyError(error.localizedDescription))
        }
    }
}

struct OnboardingView: View {
    @ObservedObject var model: AppModel
    @StateObject private var setup = OnboardingModel()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: AppModel, setup: OnboardingModel = OnboardingModel()) {
        self.model = model
        _setup = StateObject(wrappedValue: setup)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(OnboardingModel.Step.allCases, id: \.self) { step in
                    Capsule().fill(step.rawValue <= setup.step.rawValue ? Theme.accent : Theme.line)
                        .frame(width: step == setup.step ? 22 : 8, height: 8)
                }
            }
            .padding(.top, 34)
            .accessibilityElement()
            .accessibilityLabel("Step \(setup.step.rawValue + 1) of \(OnboardingModel.Step.allCases.count)")
            ZStack {
                content.id(setup.step).transition(.soft(reduceMotion))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 36)
            footer
        }
        .frame(width: 520, height: 470)
        .onDisappear { setup.cancelRehearsal() }
        .onAppear { if !Snapshot.isRunning { setup.micStatus = AVCaptureDevice.authorizationStatus(for: .audio) } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            setup.micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        }
        .background(WindowBackdrop())
        .tint(Theme.accentText)
        .animation(Motion.state(reduceMotion), value: setup.step)
        .animation(Motion.state(reduceMotion), value: setup.rehearsal)
        .animation(Motion.state(reduceMotion), value: setup.downloading)
        .tipContainerBounds()
    }

    @ViewBuilder private var content: some View {
        switch setup.step {
        case .welcome:
            page(title: "Meet Nosy", body: "Nosy transcribes lectures and meetings entirely on your Mac. Nothing is uploaded, ever.") {
                NosyMark(size: 72)
            }
        case .microphone:
            page(title: "Your microphone", body: "Nosy needs the mic to hear your lectures and meetings. macOS will ask once.") {
                status(setup.micStatus == .authorized ? "Microphone allowed" : (setup.micStatus == .notDetermined ? "Not asked yet" : "Microphone is off for Nosy"),
                       ok: setup.micStatus == .authorized)
                if setup.micStatus == .notDetermined {
                    Button("Allow microphone") { Task { await setup.requestMicrophone() } }
                        .buttonStyle(PillButtonStyle(kind: .primary, height: 38, fullWidth: false))
                        .tip("Allow microphone")
                } else if setup.micStatus != .authorized {
                    Button("Open Privacy Settings") { model.openMicrophoneSettings() }
                        .buttonStyle(PillButtonStyle(kind: .quiet, height: 38, fullWidth: false))
                        .tip("Microphone privacy")
                }
            }
        case .folder:
            page(title: "Where transcripts go", body: "Each folder groups its Markdown transcripts. You can change the transcript location any time in Settings.") {
                HStack(spacing: 10) {
                    Image(systemName: "folder.fill").foregroundStyle(Theme.accentText)
                    Text(abbreviated(model.paths.transcripts)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .fieldChrome()
                .frame(width: 340)
                Button("Choose another folder…") { model.chooseTranscriptsFolder() }
                    .buttonStyle(PillButtonStyle(kind: .quiet, height: 32, fullWidth: false))
                    .tip("Choose save folder")
                    .disabled(model.working)
            }
        case .engine:
            page(title: "The speech engine", body: "Nosy includes whisper.cpp. Download the 1.6 GB speech model to get started. Everything stays on your Mac.") {
                VStack(alignment: .leading, spacing: 12) {
                    status(setup.whisperReady(model.paths) ? "Speech engine ready" : "Speech engine missing. Reinstall Nosy.", ok: setup.whisperReady(model.paths))
                    if !setup.whisperReady(model.paths) {
                        Button("Check again") { setup.objectWillChange.send(); model.refreshDependencies() }
                            .buttonStyle(LinkButtonStyle())
                            .tip("Check speech engine")
                    }
                    status(setup.modelReady(model.paths) ? "Speech model ready" : "Speech model not downloaded", ok: setup.modelReady(model.paths))
                    if !setup.modelReady(model.paths) {
                        if setup.downloading {
                            VStack(alignment: .leading, spacing: 6) {
                                ProgressTrack(value: setup.downloadFraction, tint: Theme.accent).frame(width: 340)
                                HStack {
                                    Text(setup.downloadDetail).font(Theme.text(11.5)).foregroundStyle(Theme.muted).monospacedDigit()
                                    Spacer()
                                    Button(setup.cancelling ? "Stopping…" : "Cancel") { setup.cancelDownload() }
                                        .buttonStyle(LinkButtonStyle(tint: Theme.muted)).tip("Cancel download").disabled(setup.cancelling)
                                }.frame(width: 340)
                            }
                        } else {
                            HStack(spacing: 10) {
                                Button(setup.downloadError == nil ? "Download model (1.6 GB)" : "Resume download") { setup.startDownload(paths: model.paths) }
                                    .buttonStyle(PillButtonStyle(kind: .primary, height: 34, fullWidth: false))
                                    .tip("Download speech model")
                                Button("Use downloaded model…") { setup.useDownloadedModel(paths: model.paths) }
                                    .buttonStyle(LinkButtonStyle())
                                    .tip("Choose model file", edge: .top)
                            }
                        }
                        if let error = setup.downloadError {
                            Text(error).font(Theme.text(11.5)).foregroundStyle(Theme.coral).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .tryIt:
            page(title: "Try it", body: "Say a sentence with a tricky word. Nosy records five seconds and writes it up.") {
                rehearsal
            }
        }
    }

    @ViewBuilder private var rehearsal: some View {
        switch setup.rehearsal {
        case .ready:
            Button { setup.startRehearsal(paths: model.paths, inputUID: model.inputUID) } label: {
                Label("Record 5 seconds", systemImage: "record.circle")
            }
            .buttonStyle(PillButtonStyle(kind: .primary, height: 40, fullWidth: false))
            .tip("Record test clip")
            .disabled(model.busy || model.setupMessage != nil)
            if model.setupMessage != nil {
                Text("Finish the speech engine step first.").font(Theme.text(12)).foregroundStyle(Theme.muted)
            }
        case .recording(let remaining):
            VStack(spacing: 10) {
                Text("\(remaining)").font(Theme.text(44)).monospacedDigit().foregroundStyle(Theme.ink)
                    .contentTransition(.numericText(countsDown: true))
                Text("Listening…").font(Theme.text(12.5, .medium)).foregroundStyle(Theme.muted)
                Circle().fill(Theme.coral).frame(width: 10, height: 10)
                    .scaleEffect(reduceMotion ? 1 : 1 + CGFloat(max(0, (setup.rehearsalLevel + 50) / 50)))
                    .animation(.easeOut(duration: 0.1), value: setup.rehearsalLevel)
            }
        case .transcribing(let value):
            VStack(spacing: 8) {
                Text("Writing it up…").font(Theme.text(13, .semibold)).foregroundStyle(Theme.ink)
                ProgressTrack(value: value, tint: Theme.stop).frame(width: 280)
            }
        case .done(let text):
            VStack(spacing: 10) {
                status(text.isEmpty ? "Nosy didn't catch any words" : "It works", ok: !text.isEmpty)
                Text(text.isEmpty ? "Check that the right mic is selected and try again, a little louder." : "“\(text)”")
                    .font(Theme.text(14)).foregroundStyle(text.isEmpty ? Theme.muted : Theme.ink)
                    .multilineTextAlignment(.center).lineLimit(4)
                Button("Try again") { setup.rehearsal = .ready }.buttonStyle(LinkButtonStyle()).tip("Retry rehearsal")
            }
        case .failed(let message):
            VStack(spacing: 10) {
                status(message, ok: false)
                Button("Try again") { setup.rehearsal = .ready }.buttonStyle(LinkButtonStyle()).tip("Retry rehearsal")
            }
        }
    }

    private var footer: some View {
        HStack {
            if setup.step != .welcome {
                Button("Back") { setup.step = OnboardingModel.Step(rawValue: setup.step.rawValue - 1) ?? .welcome }
                    .buttonStyle(PillButtonStyle(kind: .quiet, height: 38, fullWidth: false))
                    .tip("Previous step")
                    .keyboardShortcut(.cancelAction)
                    .disabled(setup.rehearsing)
            }
            Spacer()
            if setup.step == .engine, model.setupMessage != nil {
                Button("Skip for now") { setup.step = .tryIt }.buttonStyle(LinkButtonStyle(tint: Theme.muted)).tip("Skip setup step")
            }
            Button(setup.step == .tryIt ? "Start using Nosy" : "Continue") {
                if let next = OnboardingModel.Step(rawValue: setup.step.rawValue + 1) {
                    setup.step = next
                    if next == .engine { model.refreshDependencies() }
                } else {
                    model.finishOnboarding()
                    dismiss()
                }
            }
            .buttonStyle(PillButtonStyle(kind: .primary, height: 38, fullWidth: false))
            .tip(setup.step == .tryIt ? "Finish setup" : "Continue setup")
            .keyboardShortcut(.defaultAction)
            .disabled(continueDisabled)
        }
        .padding(.horizontal, 28).padding(.bottom, 24)
    }
    private var continueDisabled: Bool {
        switch setup.step {
        case .engine: model.setupMessage != nil
        case .tryIt: setup.rehearsing
        default: false
        }
    }

    private func page<Extra: View>(title: String, body: String, @ViewBuilder extra: () -> Extra) -> some View {
        VStack(spacing: 16) {
            Text(title).font(Theme.display(26, .bold)).foregroundStyle(Theme.ink)
            Text(body).font(Theme.text(14)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 380)
            extra()
        }
        .frame(maxWidth: .infinity)
    }
    private func status(_ text: String, ok: Bool) -> some View {
        Label {
            Text(text).font(Theme.text(13, .semibold)).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill").foregroundStyle(ok ? Theme.green : Theme.amber)
        }
    }
    private func abbreviated(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
    }
}
