import AppKit
import AVFoundation
import Combine
import SwiftUI
import UserNotifications

enum AppPhase { case idle, recording, transcribing, done, failed }

final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate, Sendable {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        if let path = response.notification.request.content.userInfo["transcriptPath"] as? String {
            await MainActor.run { AppModel.shared.showInLibrary(URL(fileURLWithPath: path)) }
        }
    }
}

// Recording and transcription run independently: a lecture can be recorded while earlier
// ones are still transcribing. `phase` is what the main window shows for the foreground
// lecture (`current`); `active` is whichever recording the transcription queue is working on.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    @Published private(set) var paths = AppPaths()
    @Published var phase: AppPhase = .idle
    @Published var homeFromTranscribing = false
    @Published var lectures: [String] = []
    @Published var selectedLecture = "__new__"
    @Published var newLecture = ""
    @Published var session = ""
    @Published private(set) var startValidationRequest = 0
    @Published var duration: TimeInterval = 0
    @Published var transcriptionElapsed: TimeInterval = 0
    @Published var level = -160.0
    // Rolling level history (newest last) for the waveform.
    @Published var levels = Array(repeating: -160.0, count: AppModel.waveformLength)
    @Published var paused = false
    @Published private(set) var inputs: [AudioInputs.Device] = []
    @Published private(set) var systemInput: AudioInputs.Device?
    @Published private(set) var inputUID = UserDefaults.standard.string(forKey: "inputDeviceUID")
    @Published private(set) var activeInputName: String?
    @Published private(set) var recordingSource = RecordingSource.restored(UserDefaults.standard.string(forKey: "recordingSource"))
    @Published private(set) var macAudioDenied = false
    @Published private(set) var macAudioQuiet = false
    @Published var transcriptionProgress = 0.0
    @Published private(set) var transcriptionPauseReason: String?
    @Published var silenceWarning = false
    @Published var stalled = false
    @Published var sleepNotice: String?
    @Published var errorMessage: String?
    @Published var errorDetail: String?
    @Published var microphoneDenied = false
    @Published var setupMessage: String?
    @Published var recovery: [SessionRecord] = []
    @Published var transitioning = false
    @Published var current: SessionRecord? { didSet { refreshSavedTranscript() } }
    @Published private(set) var savedSummary = SavedSummary()
    @Published private(set) var active: SessionRecord?
    @Published private(set) var queue: [SessionRecord] = []
    // A transcript the Transcripts window should select when it next appears or updates.
    @Published var libraryFocus: URL?
    // Set by any open window so the model can open others (e.g. from a notification).
    var openWindow: OpenWindowAction?
    var finishLibraryEditing: (() -> Bool)?

    private var recorder: Recorder?
    private var job: TranscriptionJob?
    private var worker: Task<Void, Never>?
    private var activity: NSObjectProtocol?
    private var timer: Timer?
    private var powerTimer: Timer?
    private var activityOptions: ProcessInfo.ActivityOptions = []
    private var transcriptionStarted: Date?
    private var sleptAt: Date?
    // Recorded length at the last "still recording" reminder; 0 means none sent yet.
    private var lastReminder: TimeInterval = 0
    private var reminderHours: Int { UserDefaults.standard.object(forKey: "remindAfterHours") as? Int ?? 3 }
    private let notificationDelegate = NotificationDelegate()
    private var observers: [NSObjectProtocol] = []
    private var launched = false
    private var quitting = false
    // Claimed synchronously by Stop or a recorder failure, so only one of them finishes a recording.
    private var completing = false
    static let waveformLength = 46
    static var today: String { Core.dateString(Date(), format: "yyyy-MM-dd") }

    var recording: Bool { phase == .recording }
    // Course/session fields lock while a recording starts, runs or stops.
    var busy: Bool { phase == .recording || transitioning }
    var working: Bool { busy || active != nil || !queue.isEmpty }
    var lectureName: String { selectedLecture == "__new__" ? newLecture : selectedLecture }
    var hasLecture: Bool { !lectureName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var canStart: Bool {
        !busy && hasLecture && !session.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    // The foreground lecture is waiting behind another transcription.
    var waiting: Bool { phase == .transcribing && current != nil && current?.id != active?.id }
    var micLocked: Bool { !RecordingSource.canChange(recording: recording, paused: paused, transitioning: transitioning) }
    var transcriptionRemaining: TimeInterval? {
        guard transcriptionProgress > 0.04, transcriptionProgress < 1 else { return nil }
        return transcriptionElapsed / transcriptionProgress * (1 - transcriptionProgress)
    }

    func launch() {
        guard !launched else { return }; launched = true
        do { try Core.migrateLegacy(paths: paths) } catch { showError("Couldn't move your old Lecture Transcriber files: \(error.localizedDescription)") }
        let center = UNUserNotificationCenter.current()
        center.delegate = notificationDelegate
        if !UserDefaults.standard.bool(forKey: "requestedNotifications") {
            center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
            UserDefaults.standard.set(true, forKey: "requestedNotifications")
        }
        // Pin the resolved folder so a default never silently changes under someone.
        if ProcessInfo.processInfo.environment["NOSY_TRANSCRIPTS_DIR"] == nil,
           UserDefaults.standard.string(forKey: AppPaths.transcriptsKey) == nil {
            UserDefaults.standard.set(paths.transcripts.path, forKey: AppPaths.transcriptsKey)
        }
        refreshDependencies()
        refreshInputs()
        refreshLectures()
        if let last = UserDefaults.standard.string(forKey: "lastLecture"), lectures.contains(last) { selectedLecture = last }
        observeSystem()
        transitioning = true
        let paths = paths
        Task {
            do {
                recovery = try await Task.detached {
                    try paths.prepareSupport()
                    let recovered = try Core.recover(paths: paths)
                    try Core.applyRetention(paths: paths)
                    return recovered
                }.value
            } catch { showError(error.localizedDescription) }
            transitioning = false
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }
    var needsOnboarding: Bool { !UserDefaults.standard.bool(forKey: "onboarded") }
    func finishOnboarding() {
        UserDefaults.standard.set(true, forKey: "onboarded")
        refreshDependencies()
        reloadPaths()
    }

    private func observeSystem() {
        observers.append(NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateStress() }
        })
        powerTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateStress() }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.recording == true { self?.sleptAt = Date() } }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.woke() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.busy else { return }
                self.refreshDependencies()
                self.refreshLectures()
            }
        })
    }
    // Closing the lid sleeps the Mac no matter what an app asks; say so instead of leaving a silent gap.
    private func woke() {
        updateStress()
        guard let sleptAt else { return }
        self.sleptAt = nil
        guard recording else { return }
        recorder?.recoverAfterWake()
        let minutes = max(1, Int((Date().timeIntervalSince(sleptAt) / 60).rounded()))
        sleepNotice = "Recording paused while your Mac was asleep (\(minutes) min). Keep the lid open while recording."
        notify("Nosy missed \(minutes) min while your Mac was asleep")
    }

    private func showError(_ raw: String) {
        errorMessage = Core.friendlyError(raw)
        errorDetail = raw
    }
    func clearError() { errorMessage = nil; errorDetail = nil }
    func refreshDependencies() { setupMessage = Core.setupMessage(paths: paths) }
    func refreshLectures() {
        lectures = paths.lectures()
        if selectedLecture != "__new__", !lectures.contains(selectedLecture) { selectedLecture = lectures.first ?? "__new__" }
    }
    private func notify(_ title: String, path: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.sound = .default
        if let path { content.userInfo = ["transcriptPath": path] }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { _ in }
    }
    // Keeps the Mac from idling to sleep while anything is recording or transcribing.
    private func updateActivity() {
        let needed = recording || transitioning || (transcriptionPauseReason == nil && (job != nil || !queue.isEmpty))
        let options: ProcessInfo.ActivityOptions = recording || transitioning ? [.idleSystemSleepDisabled, .userInitiated] : [.idleSystemSleepDisabled]
        if let activity, options != activityOptions {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        if needed, activity == nil {
            activityOptions = options
            activity = ProcessInfo.processInfo.beginActivity(options: options, reason: "Recording and transcribing audio")
        } else if !needed, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }
    private func tick() {
        // Duration comes from recorder level events; polling the recorder here could block on disk syncs.
        if recording {
            // The deadline is computed each tick, so changing the setting mid-lecture applies at once.
            let hours = reminderHours
            let due = lastReminder == 0 ? TimeInterval(hours * 3600) : lastReminder + 3600
            if hours > 0, duration >= due {
                notify("Still recording. \(Core.reminderTime(duration)). Forgot to stop?")
                lastReminder = duration
            }
        }
        if active != nil, let transcriptionStarted {
            transcriptionElapsed = Date().timeIntervalSince(transcriptionStarted)
        }
    }

    // MARK: Recording

    func start() {
        guard !busy else { return }
        guard !session.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            startValidationRequest += 1
            return
        }
        guard canStart else { return }
        transitioning = true
        clearError()
        sleepNotice = nil
        let previous = current
        Task {
            do {
                // An existing folder is used as-is so its name (and vocab.txt) always match.
                let lecture = selectedLecture == "__new__" ? try resolvedNewLecture() : selectedLecture
                let session = try Core.sanitize(session)
                if recordingSource.usesMic { try await requestMicrophoneAccess() }
                macAudioDenied = false
                macAudioQuiet = false
                microphoneDenied = false
                try paths.prepareSupport()
                if try Core.availableDiskSpace(at: paths.support) < 2_000_000_000 {
                notify("Low disk space. Less than 2 GB available.")
                    let alert = NSAlert()
                    alert.messageText = "Low disk space"
                    alert.informativeText = "Less than 2 GB is available for audio. Continue recording?"
                    alert.addButton(withTitle: "Continue"); alert.addButton(withTitle: "Cancel")
                    guard alert.runModal() == .alertFirstButtonReturn else { transitioning = false; updateActivity(); return }
                }
                try FileManager.default.createDirectory(at: paths.lectureFolder(lecture), withIntermediateDirectories: true)
                let record = SessionRecord(id: Core.newID(in: paths), lecture: lecture, session: session, startedAt: Date(), status: .recording)
                try record.save(in: paths)
                current = record
                activeInputName = nil
                let recorder = Recorder(inputUID: inputUID, source: recordingSource) { [weak self = self] event in Task { @MainActor in self?.handle(event, id: record.id) } }
                self.recorder = recorder
                updateActivity()
                try await recorder.start(at: paths.audioFile(record.id, "pcm"))
                // A failure or quit during startup already finished this recording; don't show it as live.
                guard self.recorder === recorder, current?.id == record.id, !completing, !quitting else {
                    if self.recorder === recorder, !completing, !quitting {
                        _ = try? await recorder.stop()
                        self.recorder = nil
                    }
                    // A failure in progress finishes (and unlocks) on its own.
                    if !completing { transitioning = false; updateActivity() }
                    return
                }
                duration = 0
                level = -160
                levels = Array(repeating: -160, count: Self.waveformLength)
                paused = false
                silenceWarning = false
                stalled = false
                lastReminder = 0
                phase = .recording
                selectedLecture = lecture
                newLecture = ""
                self.session = session
                refreshLectures()
                UserDefaults.standard.set(lecture, forKey: "lastLecture")
                notify("Recording \(lecture) · \(session)")
            } catch {
                if error is MacAudioError { macAudioDenied = true }
                if let record = current, record.status == .recording, record.id != previous?.id {
                    await failRecording(error.localizedDescription)
                } else {
                    // Nothing was recorded; the window keeps showing whatever it shows now
                    // (a background transcription may have finished meanwhile).
                    showError(error.localizedDescription)
                }
            }
            transitioning = false
            updateActivity()
        }
    }
    // A new name that matches an existing lecture apart from capitals reuses that folder.
    private func resolvedNewLecture() throws -> String {
        let name = try Core.sanitize(newLecture)
        return lectures.first { $0.caseInsensitiveCompare(name) == .orderedSame } ?? name
    }
    private func handle(_ event: RecorderEvent, id: String) {
        guard current?.id == id, !quitting else { return }
        switch event {
        case .level(let bytes, let db, let silent):
            guard recording else { return }
            duration = Core.duration(pcmBytes: bytes); level = db; silenceWarning = silent
            levels.removeFirst(); levels.append(db)
        case .input(let name):
            activeInputName = name
        case .usingDefaultInput:
            notify("Your chosen microphone isn't connected. Recording with the system default.")
        case .stalled:
            guard recording, !paused else { return }
            stalled = true
            notify(recordingSource.usesMacAudio ? "Nosy lost a recording source. Check Mac audio and your microphone." : "Nosy isn't receiving any audio. Check your microphone.")
        case .flowing:
            stalled = false
        case .macAudioQuiet(let quiet):
            guard recording, recordingSource.usesMacAudio else { return }
            macAudioQuiet = quiet
        case .silence:
            guard recording else { return }
            silenceWarning = true
            notify("Mic hears nothing. Check your input.")
        case .failed(let message, let bytes):
            if message.contains("Mac audio access was denied") { macAudioDenied = true }
            guard recording || transitioning, !completing else { return }
            completing = true
            transitioning = true
            duration = Core.duration(pcmBytes: bytes)
            Task { await failRecording(message) }
        }
    }
    private func failRecording(_ message: String) async {
        transitioning = true
        _ = try? await recorder?.stop()
        recorder = nil
        if var record = current {
            record.status = .failed
            record.endedAt = Date()
            record.error = message
            do {
                try record.save(in: paths)
                let paths = paths
                _ = try await Task.detached { [id = record.id, paths] in try Core.finalizeWAV(id: id, paths: paths) }.value
            } catch { record.error = "\(message)\n\(error.localizedDescription)"; try? record.save(in: paths) }
            current = record
        }
        phase = .failed
        paused = false
        completing = false
        showError(current?.error ?? message)
        silenceWarning = false
        stalled = false
        transitioning = false
        updateActivity()
        resetSession()
        notify("Recording stopped unexpectedly")
    }
    func addMarker() {
        guard recording, !transitioning, !completing, !quitting, var record = current else { return }
        record.markers.append(SessionMarker(t: duration))
        saveMarkers(record)
    }
    func editMarker(at index: Int, label: String) {
        guard recording, !transitioning, !quitting, var record = current, record.markers.indices.contains(index) else { return }
        record.markers[index].label = label
        saveMarkers(record)
    }
    private func saveMarkers(_ record: SessionRecord) {
        do {
            // Persist before publishing so the list never claims an unsaved marker is safe.
            try record.save(in: paths)
            current = record
        } catch { showError("Could not save marker: \(error.localizedDescription)") }
    }
    func togglePause() {
        guard recording, !transitioning, let recorder else { return }
        paused.toggle()
        recorder.setPaused(paused)
        if paused {
            macAudioQuiet = false
            silenceWarning = false
            stalled = false
            levels = Array(repeating: -160, count: Self.waveformLength)
        }
    }
    func stop() {
        guard recording, !transitioning, !completing else { return }
        transitioning = true
        completing = true
        paused = false
        Task {
            do {
                duration = Core.duration(pcmBytes: try await recorder?.stop() ?? 0)
                recorder = nil
                guard !quitting else { return }  // prepareToQuit owns the recording now
                guard var record = current else { throw LectureError.message("No recording to transcribe.") }
                record.endedAt = Date()
                record.status = .transcribing
                try? record.save(in: paths)
                current = record
                completing = false
                silenceWarning = false
                stalled = false
                sleepNotice = nil
                phase = .transcribing
                transitioning = false
                resetSession()
                enqueue(record)
            } catch { await failRecording(error.localizedDescription) }
        }
    }

    // MARK: Transcription queue

    // The live recording can't be transcribed until it stops (its file is still being written).
    func isLive(_ id: String) -> Bool { (recording || transitioning) && current?.id == id }
    func retry(_ record: SessionRecord? = nil) {
        guard let record = record ?? current, !isQueued(record.id), !isLive(record.id) else { return }
        recovery.removeAll { $0.id == record.id }
        // During a Start or Stop the foreground belongs to that recording; just queue this one.
        if !recording, !transitioning {
            current = record
            phase = .transcribing
            clearError()
        }
        enqueue(record)
    }
    func isQueued(_ id: String) -> Bool { active?.id == id || queue.contains { $0.id == id } }
    private func enqueue(_ record: SessionRecord) {
        guard !isQueued(record.id) else { return }
        queue.append(record)
        updateActivity()
        pump()
    }
    private func refreshStress() {
        let power = Core.powerState()
        transcriptionPauseReason = Core.stressReason(thermal: ProcessInfo.processInfo.thermalState, onBattery: power.onBattery, percent: power.percent)
        if transcriptionPauseReason != nil {
            job?.suspend()
            if let transcriptionStarted {
                transcriptionElapsed = Date().timeIntervalSince(transcriptionStarted)
                self.transcriptionStarted = nil
            }
        } else {
            job?.resume()
            if active != nil, transcriptionStarted == nil { transcriptionStarted = Date().addingTimeInterval(-transcriptionElapsed) }
        }
        updateActivity()
    }
    private func updateStress() {
        refreshStress()
        if transcriptionPauseReason == nil { pump() }
    }
    private func pump() {
        guard job == nil, !quitting, !queue.isEmpty else { updateActivity(); return }
        refreshStress()
        guard transcriptionPauseReason == nil else { return }
        let record = queue.removeFirst()
        let job = TranscriptionJob()
        self.job = job
        active = record
        transcriptionStarted = Date()
        transcriptionElapsed = 0
        transcriptionProgress = 0
        refreshDependencies()
        updateActivity()
        let paths = paths
        worker = Task {
            do {
                let result = try await Transcriber.transcribe(record: record, paths: paths, job: job) { [weak self] value in
                    Task { @MainActor in
                        guard let self, self.job === job else { return }
                        self.transcriptionProgress = max(self.transcriptionProgress, value)
                    }
                }
                guard !quitting else { return }
                finished(record, result: result, error: nil)
            } catch {
                guard !quitting else { return }
                let stored = (try? SessionRecord.read(paths.audioFile(record.id, "json"))) ?? record
                finished(stored, result: nil, error: error)
            }
        }
    }
    private func finished(_ record: SessionRecord, result: SessionRecord?, error: Error?) {
        transcriptionStarted = nil
        job = nil
        active = nil
        let foreground = phase == .transcribing && current?.id == record.id
        if let result {
            recovery.removeAll { $0.id == record.id }
            if foreground { current = result; phase = .done }
            let markdown = result.transcriptPath.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
            let outcome = markdown.map { Core.wordCount($0) == 0 } == true ? "No speech detected" : "Transcript saved"
            notify("\(outcome). \(result.lecture) · \(result.session)", path: result.transcriptPath)
        } else if let error {
            if foreground {
                current = record
                phase = .failed
                showError(error.localizedDescription)
            }
            notify("Transcription failed. \(record.lecture) · \(record.session)")
        }
        pump()
    }

    // MARK: Recovery

    // "Later" hides the banner for now; the recording stays in Transcripts › Unfinished.
    func postponeRecovery() {
        guard !recovery.isEmpty else { return }
        recovery.removeFirst()
    }
    func deleteRecording(_ record: SessionRecord) {
        guard !isQueued(record.id), current?.id != record.id || !busy else { return }
        let alert = NSAlert()
        alert.messageText = "Delete the audio for \(record.lecture) · \(record.session)?"
        alert.informativeText = "This recording hasn't been transcribed. Deleting it can't be undone."
        alert.alertStyle = .warning
        let delete = alert.addButton(withTitle: "Delete")
        delete.hasDestructiveAction = true
        delete.keyEquivalent = ""
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\r"
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try AudioFiles.deleteAudio(id: record.id, paths: paths)
            recovery.removeAll { $0.id == record.id }
            if current?.id == record.id, phase == .failed { current = nil; phase = .idle; clearError() }
        } catch { showError(error.localizedDescription) }
    }

    // MARK: Import

    func importRecording() {
        let panel = NSOpenPanel()
        panel.title = "Import a recording"
        panel.prompt = "Import"
        panel.allowedContentTypes = [.audio, .movie]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importRecording(url)
    }
    func importRecording(_ url: URL) {
        guard !busy else { return }
        clearError()
        let paths = paths
        let lectureInput = selectedLecture == "__new__" ? newLecture : selectedLecture
        let sessionInput = session
        transitioning = true
        Task {
            do {
                let lecture = selectedLecture == "__new__" ? try resolvedNewLecture() : try Core.sanitize(lectureInput)
                let session = try Core.sanitize(sessionInput)
                let record = try await Task.detached {
                    try AudioFiles.importRecording(from: url, lecture: lecture, session: session, paths: paths)
                }.value
                transitioning = false
                selectedLecture = lecture
                newLecture = ""
                refreshLectures()
                resetSession()
                retry(record)
            } catch {
                transitioning = false
                showError(error.localizedDescription)
            }
            updateActivity()
        }
    }

    // MARK: Vocabulary

    func vocabularyURL(for lecture: String) -> URL? {
        let name = lecture.trimmingCharacters(in: .whitespaces)
        guard let safe = try? Core.sanitize(name) else { return nil }
        return paths.lectureFolder(safe).appendingPathComponent("vocab.txt")
    }
    func vocabulary(for lecture: String) -> String {
        vocabularyURL(for: lecture).flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    }
    var vocabularySubject: String {
        guard let folder = vocabularyURL(for: lectureName)?.deletingLastPathComponent(),
              let settings = try? SubjectSettings.load(folder: folder) else { return "General" }
        let primary = settings.canonicalSubject == "auto" ? SubjectCatalog.guess(lectureName).first ?? "general" : settings.canonicalSubject
        return SubjectCatalog.name(for: primary)
    }
    @discardableResult func saveVocabulary(_ text: String, for lecture: String, settings: SubjectSettings? = nil) -> Bool {
        guard let url = vocabularyURL(for: lecture) else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            } else {
                try Data(text.utf8).write(to: url, options: .atomic)
            }
            if let settings { try settings.save(folder: url.deletingLastPathComponent()) }
            refreshLectures()
            return true
        } catch { showError(error.localizedDescription); return false }
    }

    // MARK: Session, inputs, folders

    // The next recording always starts with an empty session name.
    private func resetSession() {
        session = ""
    }
    func revealTranscript() {
        refreshSavedTranscript()
        if savedSummary.markdown != nil, let path = current?.transcriptPath { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
    }
    func refreshSavedTranscript() { savedSummary = SavedSummary(record: current, model: self) }
    func transcriptChanged(from old: URL, to new: URL?) {
        guard current?.transcriptPath == old.path else { return }
        current?.transcriptPath = new?.path
        refreshSavedTranscript()
    }
    func showInLibrary(_ url: URL?) {
        libraryFocus = url
        NSApp.activate(ignoringOtherApps: true)
        openWindow?(id: "library")
    }
    var inputName: String {
        recordingSource.inputName(mic: microphoneName)
    }
    var microphoneName: String {
        (recording ? activeInputName : nil)
            ?? inputs.first(where: { $0.id == inputUID })?.name ?? systemInput?.name ?? "System default"
    }
    private func requestMicrophoneAccess() async throws {
        let permission: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: permission = true
        case .notDetermined: permission = await AVCaptureDevice.requestAccess(for: .audio)
        default: permission = false
        }
        microphoneDenied = !permission
        guard permission else {
            throw LectureError.message("Microphone access is denied. Enable it in System Settings, then Start again.")
        }
    }
    func selectSource(_ source: RecordingSource) {
        guard !micLocked, source != recordingSource, RecordingSource.available.contains(source) else { return }
        guard recording, paused, let recorder else { commitSource(source); return }
        transitioning = true
        Task {
            do {
                if source.usesMic { try await requestMicrophoneAccess() }
                try await recorder.switchSource(source, inputUID: inputUID)
                commitSource(source)
            } catch {
                if error is MacAudioError { macAudioDenied = true }
                showError(error.localizedDescription)
            }
            transitioning = false
        }
    }
    private func commitSource(_ source: RecordingSource) {
        recordingSource = source
        UserDefaults.standard.set(source.rawValue, forKey: "recordingSource")
        macAudioDenied = false
        macAudioQuiet = false
        microphoneDenied = false
        clearError()
    }
    func refreshInputs() {
        let systemDefault = AudioInputs.systemDefault()
        let available = AudioInputs.list()
        // A hover must not rebuild a menu whose devices have not changed.
        if inputs != available { inputs = available }
        if systemInput != systemDefault { systemInput = systemDefault }
    }
    // Before recording this just saves the choice; while paused it switches the live recording.
    func selectInput(_ uid: String?) {
        guard !micLocked else { return }
        guard recording, paused, let recorder else { commitInput(uid); return }
        transitioning = true
        Task {
            do {
                try await recorder.switchInput(uid: uid)
                commitInput(uid)
            } catch { showError(error.localizedDescription) }
            transitioning = false
        }
    }
    private func commitInput(_ uid: String?) {
        inputUID = uid
        UserDefaults.standard.set(uid, forKey: "inputDeviceUID")
    }

    // Fixtures must render the real view paths without starting a recorder or queue.
    func configurePreview(active: SessionRecord? = nil, queued: [SessionRecord] = [], pauseReason: String? = nil,
                          source: RecordingSource = .mic) {
        precondition(Snapshot.isRunning)
        self.active = active
        queue = queued
        transcriptionPauseReason = pauseReason
        inputUID = nil
        recordingSource = source
        systemInput = .init(id: "preview-mic", name: "MacBook Pro Microphone")
    }
    @discardableResult func chooseTranscriptsFolder() -> Bool {
        guard !working else { return false }
        let panel = NSOpenPanel()
        panel.title = "Choose where Nosy saves transcripts"
        panel.prompt = "Use This Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = paths.transcripts
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        guard finishLibraryEditing?() != false else { return false }
        UserDefaults.standard.set(url.path, forKey: AppPaths.transcriptsKey)
        reloadPaths()
        return true
    }
    func setRetention(days: Int) {
        UserDefaults.standard.set(days, forKey: AppPaths.retentionKey)
        reloadPaths()
    }
    private func reloadPaths() {
        paths = AppPaths()
        refreshLectures()
        refreshDependencies()
    }
    func revealTranscriptsFolder() {
        try? FileManager.default.createDirectory(at: paths.transcripts, withIntermediateDirectories: true)
        NSWorkspace.shared.open(paths.transcripts)
    }
    func openMacAudioSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
    }
    func openMicrophoneSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }
    func prepareToQuit() async {
        quitting = true
        job?.cancel()
        // Let the worker settle (cancelled, or finishing a save/compression) before touching sidecars.
        await worker?.value
        if let recorder { _ = try? await recorder.stop(); self.recorder = nil }
        // Everything unfinished is kept and offered again on the next launch.
        var pending = queue
        if let active { pending.insert(active, at: 0) }
        if recording, let current { pending.insert(current, at: 0) }
        for pendingRecord in pending {
            // Re-read: a transcript may have been saved since this was queued.
            var record = (try? SessionRecord.read(paths.audioFile(pendingRecord.id, "json"))) ?? pendingRecord
            guard record.status != .done else { continue }
            record.status = .failed
            record.error = "Quit before transcription"
            record.endedAt = record.endedAt ?? Date()
            try? record.save(in: paths)
            let paths = paths
            _ = try? await Task.detached { [id = record.id, paths] in try Core.finalizeWAV(id: id, paths: paths) }.value
        }
        queue = []
        updateActivity()
    }
}
