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
    @Published var lectures: [String] = []
    @Published var selectedLecture = "__new__"
    @Published var newLecture = ""
    @Published var session = AppModel.today
    @Published var sessionEdited = false
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
    @Published var transcriptionProgress = 0.0
    @Published var silenceWarning = false
    @Published var stalled = false
    @Published var sleepNotice: String?
    @Published var errorMessage: String?
    @Published var errorDetail: String?
    @Published var microphoneDenied = false
    @Published var setupMessage: String?
    @Published var recovery: [SessionRecord] = []
    @Published var transitioning = false
    @Published var current: SessionRecord?
    @Published private(set) var active: SessionRecord?
    @Published private(set) var queue: [SessionRecord] = []
    // A transcript the Transcripts window should select when it next appears or updates.
    @Published var libraryFocus: URL?
    // Set by any open window so the model can open others (e.g. from a notification).
    var openWindow: OpenWindowAction?

    private var recorder: Recorder?
    private var job: TranscriptionJob?
    private var worker: Task<Void, Never>?
    private var activity: NSObjectProtocol?
    private var timer: Timer?
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
    // Fields and the folder button lock only while a recording starts, runs or stops.
    var busy: Bool { phase == .recording || transitioning }
    var working: Bool { busy || active != nil || !queue.isEmpty }
    var lectureName: String { selectedLecture == "__new__" ? newLecture : selectedLecture }
    var canStart: Bool {
        !busy && !lectureName.trimmingCharacters(in: .whitespaces).isEmpty && !session.trimmingCharacters(in: .whitespaces).isEmpty
    }
    // The foreground lecture is waiting behind another transcription.
    var waiting: Bool { phase == .transcribing && current != nil && current?.id != active?.id }
    var micLocked: Bool { transitioning || (recording && !paused) }
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
                if !self.sessionEdited { self.session = Self.today }
            }
        })
    }
    // Closing the lid sleeps the Mac no matter what an app asks; say so instead of leaving a silent gap.
    private func woke() {
        guard let sleptAt else { return }
        self.sleptAt = nil
        guard recording else { return }
        let minutes = max(1, Int((Date().timeIntervalSince(sleptAt) / 60).rounded()))
        sleepNotice = "Recording paused while your Mac was asleep (\(minutes) min). Keep the lid open during lectures."
        notify("Nosy missed \(minutes) min while your Mac was asleep")
    }

    private func showError(_ raw: String) {
        errorMessage = Core.friendlyError(raw)
        errorDetail = raw
    }
    func clearError() { errorMessage = nil; errorDetail = nil }
    func refreshDependencies() { setupMessage = Core.setupMessage(paths: paths) }
    func copyInstallCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Core.whisperInstallCommand, forType: .string)
    }
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
        let needed = recording || transitioning || job != nil || !queue.isEmpty
        if needed, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: "Recording and transcribing a lecture")
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
                notify("Still recording — \(Core.reminderTime(duration)). Forgot to stop?")
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
        if !sessionEdited { session = Self.today }
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
                let permission: Bool
                switch AVCaptureDevice.authorizationStatus(for: .audio) {
                case .authorized: permission = true
                case .notDetermined: permission = await AVCaptureDevice.requestAccess(for: .audio)
                default: permission = false
                }
                guard permission else {
                    microphoneDenied = true
                    throw LectureError.message("Microphone access is denied. Enable it in System Settings, then Start again.")
                }
                microphoneDenied = false
                try paths.prepareSupport()
                if try Core.availableDiskSpace(at: paths.support) < 2_000_000_000 {
                    notify("Low disk space — less than 2 GB available")
                    let alert = NSAlert()
                    alert.messageText = "Low disk space"
                    alert.informativeText = "Less than 2 GB is available for lecture audio. Continue recording?"
                    alert.addButton(withTitle: "Continue"); alert.addButton(withTitle: "Cancel")
                    guard alert.runModal() == .alertFirstButtonReturn else { transitioning = false; updateActivity(); return }
                }
                try FileManager.default.createDirectory(at: paths.lectureFolder(lecture), withIntermediateDirectories: true)
                let record = SessionRecord(id: Core.newID(in: paths), lecture: lecture, session: session, startedAt: Date(), status: .recording)
                try record.save(in: paths)
                current = record
                activeInputName = nil
                let recorder = Recorder(inputUID: inputUID) { [weak self = self] event in Task { @MainActor in self?.handle(event, id: record.id) } }
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
            notify("Your chosen microphone isn't connected — recording with the system default")
        case .stalled:
            guard recording, !paused else { return }
            stalled = true
            notify("Nosy isn't receiving any audio — check your microphone")
        case .flowing:
            stalled = false
        case .silence:
            guard recording else { return }
            silenceWarning = true
            notify("Mic hears nothing — check your input")
        case .failed(let message, let bytes):
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
    func togglePause() {
        guard recording, !transitioning, let recorder else { return }
        paused.toggle()
        recorder.setPaused(paused)
        if paused {
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
    private func pump() {
        guard job == nil, !quitting, !queue.isEmpty else { updateActivity(); return }
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
        job = nil
        active = nil
        let foreground = phase == .transcribing && current?.id == record.id
        if let result {
            recovery.removeAll { $0.id == record.id }
            if foreground { current = result; phase = .done }
            notify("Transcript saved — \(result.lecture) · \(result.session)", path: result.transcriptPath)
        } else if let error {
            if foreground {
                current = record
                phase = .failed
                showError(error.localizedDescription)
            }
            notify("Transcription failed — \(record.lecture) · \(record.session)")
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
        if !sessionEdited { session = Self.today }
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
    func saveVocabulary(_ text: String, for lecture: String) {
        guard let url = vocabularyURL(for: lecture) else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try? FileManager.default.removeItem(at: url)
            } else {
                try Data(text.utf8).write(to: url, options: .atomic)
            }
            refreshLectures()
        } catch { showError(error.localizedDescription) }
    }

    // MARK: Session, inputs, folders

    // A finished or failed lecture used the edited name; the next one starts from today's date again.
    private func resetSession() {
        sessionEdited = false
        session = Self.today
    }
    func revealTranscript() {
        if let path = current?.transcriptPath { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
    }
    func showInLibrary(_ url: URL?) {
        libraryFocus = url
        NSApp.activate(ignoringOtherApps: true)
        openWindow?(id: "library")
    }
    var inputName: String {
        if recording, let activeInputName { return activeInputName }
        return inputs.first(where: { $0.id == inputUID })?.name ?? systemInput.map { "System default (\($0.name))" } ?? "System default"
    }
    func refreshInputs() {
        let systemDefault = AudioInputs.systemDefault()
        inputs = AudioInputs.list()
        systemInput = systemDefault
    }
    // Before recording this just saves the choice; while paused it switches the live recording.
    func selectInput(_ uid: String?) {
        guard !micLocked else { return }
        inputUID = uid
        UserDefaults.standard.set(uid, forKey: "inputDeviceUID")
        guard recording, paused, let recorder else { return }
        transitioning = true
        Task {
            do { try await recorder.switchInput(uid: uid) } catch { showError(error.localizedDescription) }
            transitioning = false
        }
    }
    func chooseTranscriptsFolder() {
        guard !working else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose where Nosy saves transcripts"
        panel.prompt = "Use This Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = paths.transcripts
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.path, forKey: AppPaths.transcriptsKey)
        reloadPaths()
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
