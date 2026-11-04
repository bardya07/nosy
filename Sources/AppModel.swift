import AppKit
import AVFoundation
import Combine
import SwiftUI
import UserNotifications

enum AppPhase { case idle, recording, transcribing, done, failed }

// Recorder samples and transcription progress. Each recorder sample is one published change, and
// only the views that draw these numbers observe this object.
@MainActor
final class RecordingTelemetry: ObservableObject {
    struct Sample: Equatable {
        var duration: TimeInterval
        var level: Double
        // Rolling level history (newest last) for the waveform.
        var levels: [Double]
    }
    @Published private(set) var sample = Sample(duration: 0, level: -160, levels: Array(repeating: -160, count: AppModel.waveformLength))
    @Published var transcriptionElapsed: TimeInterval = 0
    @Published var transcriptionProgress = 0.0

    var duration: TimeInterval { sample.duration }
    var level: Double { sample.level }
    var levels: [Double] { sample.levels }

    // Publishes only when the change moves something.
    func update(_ change: (inout Sample) -> Void) {
        var next = sample
        change(&next)
        if next != sample { sample = next }
    }
    // One recorder sample is one change: the length, the level and the waveform move together.
    func record(duration: TimeInterval, level: Double) {
        update { sample in
            sample.duration = duration
            sample.level = level
            sample.levels.removeFirst()
            sample.levels.append(level)
        }
    }
}

// The recorder's samples are folded once here. Views only receive an update when advice changes.
@MainActor
final class RecordingGuidancePresentation: ObservableObject {
    @Published private(set) var band: RecordingLevelGuidance.Band = .quiet
    private var accumulator = RecordingLevelGuidance()

    func reset() {
        accumulator.reset()
        publishBandIfChanged()
    }

    func record(level: Int, at time: TimeInterval) {
        _ = accumulator.add(level, at: time)
        publishBandIfChanged()
    }

    private func publishBandIfChanged() {
        if band != accumulator.band { band = accumulator.band }
    }
}

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
    @Published private(set) var libraryLocations: [URL] = []
    @Published var selectedLecture = "__new__"
    @Published var newLecture = ""
    @Published var session = ""
    @Published private(set) var startValidationRequest = 0
    // Recorder samples and transcription progress change several times a second, so they live in
    // `telemetry`. Only the views that show them observe it; the accessors below keep callers unchanged.
    let telemetry = RecordingTelemetry()
    let levelGuidance = RecordingGuidancePresentation()
    var duration: TimeInterval {
        get { telemetry.sample.duration }
        set { telemetry.update { $0.duration = newValue } }
    }
    var level: Double {
        get { telemetry.sample.level }
        set { telemetry.update { $0.level = newValue } }
    }
    // Rolling level history (newest last) for the waveform.
    var levels: [Double] {
        get { telemetry.sample.levels }
        set { telemetry.update { $0.levels = newValue } }
    }
    var transcriptionElapsed: TimeInterval {
        get { telemetry.transcriptionElapsed }
        set { telemetry.transcriptionElapsed = newValue }
    }
    var transcriptionProgress: Double {
        get { telemetry.transcriptionProgress }
        set { telemetry.transcriptionProgress = newValue }
    }
    @Published var paused = false
    @Published private(set) var inputs: [AudioInputs.Device] = []
    @Published private(set) var systemInput: AudioInputs.Device?
    @Published private(set) var inputUID: String?
    @Published private(set) var activeInputName: String?
    @Published var sourcePickerRequest = 0
    @Published private(set) var recordingSource = RecordingSource.restored(UserDefaults.standard.string(forKey: "recordingSource"))
    @Published private(set) var macAudioDenied = false
    @Published private(set) var macAudioQuiet = false
    @Published private(set) var transcriptionPauseReason: String?
    @Published var silenceWarning = false
    @Published var stalled = false
    @Published var sleepNotice: String?
    @Published var errorMessage: String?
    @Published var errorDetail: String?
    @Published var microphoneDenied = false
    @Published var setupMessage: String?
    @Published private(set) var checkingSpeechModel = false
    @Published private(set) var speechModelReady = false
    private var dependencyCheckGeneration = 0
    @Published var recovery: [SessionRecord] = []
    @Published var transitioning = false
    @Published var current: SessionRecord? { didSet { refreshSavedTranscript() } }
    @Published private(set) var savedSummary = SavedSummary()
    @Published private(set) var active: SessionRecord?
    @Published private(set) var queue: [SessionRecord] = []
    @Published private(set) var importsInProgress = 0
    // Bumped when a transcript or recording is written or queued, so the Library reads its folder again.
    @Published private(set) var libraryRevision = 0
    // A transcript the Library should select when it next appears or updates.
    @Published var libraryFocus: URL?
    // Summaries run after transcription, one at a time, and never hold up the queue.
    let summaries = SummaryCenter()
    let workspace = WorkspaceNavigation()
    var finishLibraryEditing: (() -> Bool)?
    // The Library drops a trashed folder from its tree through this, wherever it was trashed.
    var onFolderTrashed: ((String, AppPaths) -> Void)?
    var finishOnboardingWork: (() async -> Void)?

    private var recorder: Recorder?
    // Owned once, from launch: CoreAudio notifications refresh the microphone list while the app runs.
    private var inputWatcher: AudioInputs.Watcher?
    private var job: TranscriptionJob?
    private var worker: Task<Void, Never>?
    private var importer: Task<Void, Never>?
    private var importWork: Task<SessionRecord, Error>?
    private var activity: NSObjectProtocol?
    private var timer: Timer?
    private var powerTimer: Timer?
    private var activityOptions: ProcessInfo.ActivityOptions = []
    private var transcriptionStarted: Date?
    private var sleptAt: Date?
    // Recorded length at the last "still recording" reminder; 0 means none sent yet.
    private var lastReminder: TimeInterval = 0
    // Minutes between "still recording" reminders, read from Settings. Zero means never.
    private var reminderMinutes: Int { ReminderInterval.stored() }
    private let notificationDelegate = NotificationDelegate()
    private var observers: [NSObjectProtocol] = []
    private var launched = false
    // Folder names and libraries are read off the main actor; requests made during a read run once it ends.
    private var lecturesRefreshing = false
    private var lecturesNeedRefresh = false
    // The folder the last session used, selected once the first folder list arrives.
    private var rememberedLecture: String?
    private var encoderWork: Task<Void, Never>?
    var hasEncoderWork: Bool { encoderWork != nil }
    private var encoderAttempted = false
    private var quitting = false
    // Claimed synchronously by Stop or a recorder failure, so only one of them finishes a recording.
    private var completing = false
    static let waveformLength = 46
    private static let roomInputPreferenceKey = "roomAudioInputDevice"
    private static let macInputPreferenceKey = "macAudioInputDevice"
    private static let systemDefaultInputPreference = "__system_default__"
    static var today: String { Core.dateString(Date(), format: "yyyy-MM-dd") }
    private let stressReason: () -> String?
    init(stressReason: @escaping () -> String? = {
        let power = Core.powerState()
        return Core.stressReason(thermal: ProcessInfo.processInfo.thermalState, onBattery: power.onBattery, percent: power.percent)
    }) {
        self.stressReason = stressReason
        if !Snapshot.isRunning { ReminderInterval.migrate() }
        let defaults = UserDefaults.standard
        TranscriptionQuality.loadOrSelect(defaults: defaults)
        Self.migrateInputPreference(defaults)
        let reading = AudioInputs.reading()
        inputs = reading.devices
        systemInput = reading.systemDefault
        inputUID = Self.selectedInputUID(for: recordingSource, devices: reading.devices, defaults: defaults)
    }

    #if NOSY_UI_TEST
    func useTestModelValidation(_ validate: @escaping @Sendable (URL) -> Bool) { paths.useTestModelValidation(validate) }
    #endif
    var recording: Bool { phase == .recording }
    // Course/session fields lock while a recording starts, runs or stops.
    var busy: Bool { phase == .recording || transitioning }
    var working: Bool { busy || importsInProgress > 0 || active != nil || !queue.isEmpty }
    var lectureName: String { selectedLecture == "__new__" ? newLecture : selectedLecture }
    private func rememberLibrary(_ folder: URL) {
        let previous = UserDefaults.standard.stringArray(forKey: "previousTranscriptLibraries") ?? []
        UserDefaults.standard.set(Array(([folder.path] + previous.filter { $0 != folder.path }).prefix(20)), forKey: "previousTranscriptLibraries")
    }
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
        // A saved root is already established, even when it is empty or temporarily unavailable.
        // Dedicated subfolders are chosen only when the user selects a new location.
        summaries.waitReason = { [weak self] provider in self?.summaryWaitReason(provider) }
        refreshDependencies()
        rememberedLecture = UserDefaults.standard.string(forKey: "lastLecture")
        let watcher = AudioInputs.Watcher { [weak self] reading in self?.applyInputs(reading) }
        watcher.start()
        inputWatcher = watcher
        refreshInputs()
        refreshLectures()
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
            // Recovery and retention can finalize or remove audio after Library's first read.
            libraryRevision += 1
            transitioning = false
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
    func refreshDependencies() {
        dependencyCheckGeneration += 1
        let generation = dependencyCheckGeneration
        let paths = paths
        checkingSpeechModel = true
        setupMessage = "Checking speech model…"
        Task {
            let result = await Task.detached(priority: .utility) {
                let ready = SpeechModel.validate(paths.model)
                var messages: [String] = []
                if paths.whisper == nil { messages.append(Core.missingEngineMessage) }
                if !ready { messages.append("Nosy needs a valid speech model (1.6 GB). Download it again in setup.") }
                return (ready, messages.isEmpty ? nil : messages.joined(separator: "\n"))
            }.value
            guard generation == dependencyCheckGeneration else { return }
            speechModelReady = result.0
            setupMessage = result.1
            checkingSpeechModel = false
            guard launched, !quitting, !encoderAttempted, result.0 else { return }
            encoderAttempted = true
            let job = TranscriptionJob()
            encoderWork = Task {
                try? await CoreMLEncoderDownload.install(paths: paths, job: job)
                encoderWork = nil
            }
        }
    }
    // Folder names and historical libraries are read off the main actor. Only changed results are published.
    func refreshLectures() {
        guard !lecturesRefreshing else { lecturesNeedRefresh = true; return }
        lecturesRefreshing = true
        let paths = paths
        let previous = UserDefaults.standard.stringArray(forKey: "previousTranscriptLibraries") ?? []
        let onlyCurrent = Snapshot.isRunning
        Task {
            let found = await Task.detached(priority: .utility) { () -> (lectures: [String], locations: [URL]) in
                (paths.lectures(), onlyCurrent ? [paths.transcripts]
                    : AppPaths.libraryLocations(current: paths.transcripts, previous: previous))
            }.value
            lecturesRefreshing = false
            if self.paths.transcripts == paths.transcripts, !lecturesNeedRefresh {
                if lectures != found.lectures { lectures = found.lectures }
                if libraryLocations != found.locations { libraryLocations = found.locations }
                if let rememberedLecture, selectedLecture == "__new__", newLecture.isEmpty,
                   lectures.contains(rememberedLecture) { selectedLecture = rememberedLecture }
                rememberedLecture = nil
                if selectedLecture != "__new__", !lectures.contains(selectedLecture) { selectedLecture = lectures.first ?? "__new__" }
            }
            if lecturesNeedRefresh {
                lecturesNeedRefresh = false
                refreshLectures()
            }
        }
    }
    private func notify(_ title: String, path: String? = nil) {
        guard !Snapshot.isRunning else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.sound = .default
        if let path { content.userInfo = ["transcriptPath": path] }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { _ in }
    }
    // Recording reminders use saved-audio samples; only transcription needs a separate clock.
    private func updateClock() {
        let needed = active != nil && transcriptionStarted != nil
        if needed, timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        } else if !needed, let timer {
            timer.invalidate()
            self.timer = nil
        }
    }
    // Keeps the Mac from idling to sleep while anything is recording or transcribing.
    private func updateActivity() {
        updateClock()
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
        if active != nil, let transcriptionStarted {
            transcriptionElapsed = Date().timeIntervalSince(transcriptionStarted)
        }
    }
    private func checkRecordingReminder() {
        if recording {
            // The deadline is computed each tick, so changing the setting mid-lecture applies at once.
            let interval = TimeInterval(reminderMinutes * 60)
            let due = lastReminder == 0 ? interval : lastReminder + interval
            if reminderMinutes > 0, duration >= due {
                notify("Still recording. \(Core.reminderTime(duration)). Forgot to stop?")
                lastReminder = duration
            }
        }
    }

    // MARK: Recording

    func start() {
        guard !busy, !quitting else { return }
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
                guard !quitting else { transitioning = false; return }
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
                try paths.validateLectureFolder(lecture)
                try FileManager.default.createDirectory(at: paths.lectureFolder(lecture), withIntermediateDirectories: true)
                let record = SessionRecord(id: Core.newID(in: paths), lecture: lecture, session: session, startedAt: Date(), status: .recording)
                try record.save(in: paths)
                current = record
                activeInputName = nil
                let recorder = Recorder(inputUID: inputUID, source: recordingSource) { [weak self = self] event in Task { @MainActor in self?.handle(event, id: record.id) } }
                self.recorder = recorder
                updateActivity()
                try await recorder.start(at: paths.audioFile(record.id, "pcm"), paths: paths)
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
                levelGuidance.reset()
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
            let savedDuration = Core.duration(pcmBytes: bytes)
            guard savedDuration >= duration else { return }
            // Writes accepted before Pause may finish afterwards. Keep the saved duration,
            // without reviving the paused waveform or its cleared silence warning.
            if paused { telemetry.update { $0.duration = savedDuration }; return }
            telemetry.record(duration: savedDuration, level: db)
            levelGuidance.record(level: InputLevel.estimate(db), at: savedDuration)
            if silenceWarning != silent { silenceWarning = silent }
            checkRecordingReminder()
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
            if quiet && !macAudioQuiet && !paused {
                notify("Mac audio is silent. Check Mac audio access and playback.")
            }
            macAudioQuiet = quiet
        case .silence:
            guard recording, !paused, !completing else { return }
            if !silenceWarning { silenceWarning = true }
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
        libraryRevision += 1
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
        guard recording, !transitioning else { return }
        guard let recorder else { return }
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
                libraryRevision += 1
                enqueue(record)
            } catch { await failRecording(error.localizedDescription) }
        }
    }

    // MARK: Transcription queue

    // The live recording can't be transcribed until it stops (its file is still being written).
    func isLive(_ id: String) -> Bool { (recording || transitioning) && current?.id == id }
    func retry(_ record: SessionRecord? = nil) {
        guard !quitting, let record = record ?? current, !isQueued(record.id), !isLive(record.id) else { return }
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
        transcriptionPauseReason = stressReason()
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
    func updateStress() {
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
        worker = Task { [self] in
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
        libraryRevision += 1
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
            if let warning = result.error { showError(warning) }
            if let path = result.transcriptPath, markdown.map({ Core.wordCount($0) > 0 }) == true {
                summaries.transcriptSaved(URL(fileURLWithPath: path))
            }
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

    // Same back-off as transcription; a local model also waits for whisper to finish.
    private func summaryWaitReason(_ provider: SummaryProvider) -> String? {
        if let reason = stressReason() {
            return reason.prefix(1).uppercased() + reason.dropFirst()
        }
        if provider.staysOnMac, job != nil { return "Waiting for transcription" }
        return nil
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
            libraryRevision += 1
            recovery.removeAll { $0.id == record.id }
            if current?.id == record.id, phase == .failed { current = nil; phase = .idle; clearError() }
        } catch { showError(error.localizedDescription) }
    }

    // MARK: Import

    func importRecording() {
        importRecordingPanel()
    }
    func importRecordingPanel(targetLecture: String? = nil) {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.title = "Import a recording"
        panel.prompt = "Import"
        panel.allowedContentTypes = [.audio, .movie, .video]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        importRecordings(panel.urls, targetLecture: targetLecture)
    }
    func importRecording(_ url: URL) {
        importRecordings([url])
    }
    func importRecordings(_ urls: [URL], targetLecture: String? = nil) {
        guard !busy, !quitting, !urls.isEmpty else { return }
        let supported = urls.filter(AudioImport.supports)
        let rejectedCount = urls.count - supported.count
        guard !supported.isEmpty else {
            showError("Choose an audio or video file to import.")
            return
        }
        clearError()
        let currentLecture = selectedLecture == "__new__" ? newLecture : selectedLecture
        let lectureInput = AudioImport.destinationLecture(selectedTreeLecture: targetLecture,
                                                           currentLecture: currentLecture,
                                                           availableLectures: lectures)
        importsInProgress += supported.count
        transitioning = true
        let paths = paths
        importer = Task {
            var failures: [String] = []
            for url in supported {
                guard !quitting else { break }
                do {
                    transitioning = true
                    let lecture = try Core.sanitize(lectureInput)
                    let session = try Core.sanitize(AudioImport.sessionName(for: url))
                    let work = Task.detached {
                        try AudioFiles.importRecording(from: url, lecture: lecture, session: session, paths: paths)
                    }
                    importWork = work
                    let record = try await work.value
                    importWork = nil
                    transitioning = false
                    guard !quitting else { break } // The imported audio and sidecar remain recoverable.
                    libraryRevision += 1
                    selectedLecture = lecture
                    newLecture = ""
                    refreshLectures()
                    retry(record)
                } catch {
                    importWork = nil
                    transitioning = false
                    failures.append(error.localizedDescription)
                }
                importsInProgress -= 1
            }
            importsInProgress = 0
            transitioning = false
            if rejectedCount > 0 {
                showError("Some files were skipped because they are not audio or video.")
            } else if let failure = failures.first {
                showError(failure)
            }
            updateActivity()
            importer = nil
        }
    }

    // MARK: Vocabulary

    func vocabularyURL(for lecture: String) -> URL? {
        let name = lecture.trimmingCharacters(in: .whitespaces)
        guard let safe = try? Core.sanitize(name) else { return nil }
        do { try paths.validateLectureFolder(safe) } catch { return nil }
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
            try paths.validateLectureFolder(lecture)
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
        libraryRevision += 1
        if old == new { summaries.cancelMoments(old) }
        guard current?.transcriptPath == old.path else { return }
        current?.transcriptPath = new?.path
        refreshSavedTranscript()
    }
    func showHome() {
        guard finishLibraryEditing?() ?? true else { return }
        workspace.showHome()
    }
    func showInLibrary(_ url: URL?) {
        libraryFocus = url
        NSApp.activate(ignoringOtherApps: true)
        workspace.showLibrary()
        NSApp.windows.first(where: { $0.title == "Nosy" })?.makeKeyAndOrderFront(nil)
    }
    var inputName: String {
        recordingSource.inputName(mic: microphoneName)
    }
    var microphoneName: String {
        (recording ? activeInputName : nil)
            ?? inputs.first(where: { $0.id == inputUID })?.name ?? systemInput?.name ?? "System default"
    }
    private static func inputPreferenceKey(for source: RecordingSource) -> String {
        source == .mic ? roomInputPreferenceKey : macInputPreferenceKey
    }
    private static func migrateInputPreference(_ defaults: UserDefaults) {
        guard let legacyUID = defaults.string(forKey: "inputDeviceUID") else { return }
        if defaults.object(forKey: roomInputPreferenceKey) == nil {
            defaults.set(legacyUID, forKey: roomInputPreferenceKey)
        }
        if defaults.object(forKey: macInputPreferenceKey) == nil {
            defaults.set(legacyUID, forKey: macInputPreferenceKey)
        }
        defaults.removeObject(forKey: "inputDeviceUID")
    }
    private static func selectedInputUID(for source: RecordingSource, devices: [AudioInputs.Device],
                                         defaults: UserDefaults) -> String? {
        let preference = defaults.string(forKey: inputPreferenceKey(for: source))
        if let preference {
            guard preference != systemDefaultInputPreference else { return nil }
            return devices.first { $0.id == preference }?.id
        }
        guard source == .mic else { return nil }
        return devices.first { $0.transport == .builtIn }?.id
    }
    private func selectedInputUID(for source: RecordingSource) -> String? {
        Self.selectedInputUID(for: source, devices: inputs, defaults: .standard)
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
        guard recording else { commitSource(source); return }
        guard let recorder else { return }
        let wasPaused = paused
        let oldSource = recordingSource
        let oldInputUID = inputUID
        transitioning = true
        Task {
            do {
                if source.usesMic { try await requestMicrophoneAccess() }
                if !wasPaused { recorder.setPaused(true) }
                do {
                    try await recorder.switchSource(source, inputUID: selectedInputUID(for: source))
                    if !wasPaused { try await recorder.resumeAfterSourceSwitch() }
                } catch {
                    if !wasPaused {
                        try? await recorder.switchSource(oldSource, inputUID: oldInputUID)
                        do { try await recorder.resumeAfterSourceSwitch() }
                        catch { recorder.failAfterSourceSwitch(error.localizedDescription) }
                    }
                    throw error
                }
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
        inputUID = selectedInputUID(for: source)
        UserDefaults.standard.set(source.rawValue, forKey: "recordingSource")
        macAudioDenied = false
        macAudioQuiet = false
        microphoneDenied = false
        clearError()
    }
    // Asks for a fresh device list. The read happens off the main actor and shares a pass with other requests.
    func refreshInputs() {
        inputWatcher?.request()
    }
    private func applyInputs(_ reading: AudioInputs.Reading) {
        // A hover must not rebuild a menu whose devices have not changed.
        if inputs != reading.devices { inputs = reading.devices }
        if systemInput != reading.systemDefault { systemInput = reading.systemDefault }
        let selectedUID = Self.selectedInputUID(for: recordingSource, devices: reading.devices, defaults: .standard)
        if inputUID != selectedUID { inputUID = selectedUID }
    }
    // Before recording this just saves the choice; while paused it switches the live recording.
    func selectInput(_ uid: String?) {
        guard !transitioning, !recording || paused else { return }
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
        let defaults = UserDefaults.standard
        defaults.set(uid ?? Self.systemDefaultInputPreference, forKey: Self.inputPreferenceKey(for: recordingSource))
        inputUID = Self.selectedInputUID(for: recordingSource, devices: inputs, defaults: defaults)
    }

    // Fixtures must render the real view paths without starting a recorder or queue.
    func configurePreview(active: SessionRecord? = nil, queued: [SessionRecord] = [], pauseReason: String? = nil,
                          source: RecordingSource = .mic, libraryLocations: [URL]? = nil,
                          microphones: [AudioInputs.Device] = [], selectedMicrophone: String? = nil) {
        precondition(Snapshot.isRunning)
        self.active = active
        self.libraryLocations = libraryLocations ?? [paths.transcripts]
        queue = queued
        transcriptionPauseReason = pauseReason
        inputUID = selectedMicrophone
        recordingSource = source
        systemInput = .init(id: "preview-mic", name: "MacBook Pro Microphone", transport: .builtIn)
        inputs = microphones
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
        let folder = AppPaths.dedicatedTranscripts(for: url)
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        catch { showError("Couldn't create \(folder.lastPathComponent): \(error.localizedDescription)"); return false }
        if folder.resolvingSymlinksInPath().standardizedFileURL != paths.transcripts.resolvingSymlinksInPath().standardizedFileURL {
            do { try ConnectorAccess.setAllowed(false, paths: paths) }
            catch { showError("Couldn't revoke connector access: \(error.localizedDescription)"); return false }
        }
        rememberLibrary(paths.transcripts)
        UserDefaults.standard.set(folder.path, forKey: AppPaths.transcriptsKey)
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
    // Moves a folder and its transcripts to the Trash, for either window. Refused while any recording,
    // transcription, import or summary is running, so no work lands in a folder that disappears underneath it.
    @discardableResult func trashLecture(_ lecture: String, paths trashPaths: AppPaths) -> Bool {
        guard !working, !summaries.hasPendingWork else {
            showError("Finish the current recording, transcription or summary before deleting a folder.")
            return false
        }
        do {
            try LectureFolderTrash.move(lecture, paths: trashPaths)
        } catch {
            showError("Couldn't move \"\(lecture)\" to the Trash: \(error.localizedDescription)")
            return false
        }
        // The last saved transcript may have lived in that folder; Saved actions must stop pointing at it.
        if let path = current?.transcriptPath, Core.isContained(URL(fileURLWithPath: path), in: trashPaths.lectureFolder(lecture)) {
            transcriptChanged(from: URL(fileURLWithPath: path), to: nil)
        }
        // refreshLectures picks another folder, or New folder, when the selected one is gone.
        refreshLectures()
        onFolderTrashed?(lecture, trashPaths)
        return true
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
        encoderWork?.cancel()
        await encoderWork?.value
        inputWatcher?.invalidate()
        inputWatcher = nil
        summaries.cancelAll()
        job?.cancel()
        importWork?.cancel()
        await finishOnboardingWork?()
        await importer?.value
        // Let the worker settle (cancelled, or finishing a save/compression) before touching sidecars.
        await worker?.value
        await summaries.shutdown()
        if let recorder { _ = try? await recorder.stop(); self.recorder = nil }
        // Everything unfinished is kept and offered again on the next launch.
        var pending = queue
        if let active { pending.insert(active, at: 0) }
        if let current, current.status == .recording { pending.insert(current, at: 0) }
        for pendingRecord in pending {
            // Re-read: a transcript may have been saved since this was queued.
            var record = (try? SessionRecord.read(paths.audioFile(pendingRecord.id, "json"))) ?? pendingRecord
            guard record.status != .done else { continue }
            record.status = .failed
            record.error = "Quit before transcription"
            record.endedAt = record.endedAt ?? Date()
            try? record.save(in: paths)
            // Raw PCM and an interrupted WAV finalization are recoverable at launch. Quit must
            // not restart the potentially long conversion that it just cancelled in the worker.
        }
        queue = []
        active = nil
        job = nil
        worker = nil
        phase = .idle
        transitioning = false
        updateActivity()
    }
}
