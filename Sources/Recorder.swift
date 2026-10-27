import AVFoundation
import Foundation
import os
#if canImport(NosyAudioBridge)
import NosyAudioBridge
#endif

enum RecorderEvent: Sendable {
    case level(bytes: Int64, db: Double, silent: Bool)
    case silence
    case usingDefaultInput
    case input(name: String)
    case stalled
    case flowing
    case macAudioQuiet(Bool)
    case failed(String, bytes: Int64)
}

struct MicrophoneConfiguration: Equatable, Sendable {
    let deviceUID: String?
    let sampleRate: Double
    let channels: UInt32
}

struct CaptureRestartLimiter {
    private(set) var starts: [TimeInterval] = []

    mutating func allowStart(at time: TimeInterval) -> Bool {
        starts.removeAll { time >= $0 && time - $0 >= 10 }
        guard starts.count < 3 else { return false }
        starts.append(time)
        return true
    }

    mutating func reset() { starts.removeAll(keepingCapacity: true) }
}

enum CaptureCallbackGate {
    static func accepts(recording: Bool, failed: Bool, paused: Bool,
                        callbackGeneration: UInt64, currentGeneration: UInt64,
                        allowPausedHeartbeat: Bool = true) -> Bool {
        recording && !failed && callbackGeneration == currentGeneration
            && (allowPausedHeartbeat || !paused)
    }

    static func acceptsConfiguration(generation: UInt64, currentGeneration: UInt64,
                                     sameEngine: Bool) -> Bool {
        generation == currentGeneration && sameEngine
    }
}

// The control queue owns engine lifecycle. The lock protects converter and counter state
// shared with the real-time tap; the writer queue alone performs disk I/O. No tap callback
// accesses UI or MainActor state, and no tap callback waits for the writer.
final class Recorder: @unchecked Sendable {
    private let control = DispatchQueue(label: "com.bardya.nosy.recorder", qos: .userInitiated)
    private let writer = DispatchQueue(label: "com.bardya.nosy.recorder.writer", qos: .userInitiated)
    private let sessionID = UUID().uuidString
    private let logger = Logger(subsystem: "com.bardya.nosy", category: "AudioCapture")
    private let lock = NSLock()
    private let inputUID: String?
    private let macCaptureFactory: @Sendable (String, UInt64) throws -> any SystemAudioCapturing
    private var source: RecordingSource // Protected by lock when accessed by audio callbacks.
    private var macCapture: (any SystemAudioCapturing)? // Control queue owns lifecycle.
    private var micConverter: CaptureConverter?
    private var macConverter: CaptureConverter?
    private var mixer: CaptureMixer?
    private var mixLatency = CaptureMixer.latency
    private var lastMacBuffer: TimeInterval = 0
    private var lastRenderTime: TimeInterval = 0
    private var lastTapCheck: TimeInterval = 0
    private var tapStalled = false
    private var lastMacSignal: TimeInterval = 0
    private var macQuietReported = false
    private var pinnedUID: String? // Owned by control; never follows later default-device changes.
    private let onEvent: @Sendable (RecorderEvent) -> Void
    private var defaultInputReported = false // Owned by the control queue; once per start.
    private var engine: AVAudioEngine?
    private var observer: NSObjectProtocol?
    private var captureGeneration: UInt64 = 0 // Control queue only.
    private var micCallbackGeneration: UInt64 = 0 // Protected by lock.
    private var macCallbackGeneration: UInt64 = 0 // Protected by lock.
    private var pauseGeneration: UInt64 = 0 // Protected by lock.
    private var restartWork: DispatchWorkItem?
    private var restartWorkToken: UUID?
    private var restartLimiter = CaptureRestartLimiter()
    private var activeMicConfiguration: MicrophoneConfiguration?
    private var sourcesActive = false
    private var stallTimer: DispatchSourceTimer?
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?
    private var monoFormat: AVAudioFormat?
    private var micRate: Double = 0 // Format the mic converters were built for; protected by lock.
    private var micChannels: AVAudioChannelCount = 0
    private var file: FileHandle? // Writer queue only.
    private var lastSync: TimeInterval = 0 // Writer queue only.
    private static let maxPendingBytes = 64_000 // Two seconds of 16 kHz mono PCM.
    private var pendingBytes = 0 // Protected by lock; accepted PCM not yet written.
    private var queuedBytes: Int64 = 0 // Protected by lock; accepted PCM, the clock for silence detection.
    private var bytes: Int64 = 0 // Protected by lock; saved PCM, published by the writer after each write.
    private var accepting = false
    private var paused = false
    private var failed = false
    private var stoppedAt: TimeInterval? // Protected by lock; excludes HAL teardown time from the saved tail.
    private var lastMeter: TimeInterval = 0
    private var silenceStart: Int64?
    private var silenceWarned = false
    private var lastBuffer: TimeInterval = 0 // Wall-clock buffer arrival, protected by lock.
    private var stalled = false

    init(inputUID: String? = nil, source: RecordingSource = .mic,
         macCaptureFactory: @escaping @Sendable (String, UInt64) throws -> any SystemAudioCapturing = { session, generation in
             guard #available(macOS 14.4, *) else {
                 throw LectureError.message("Mac audio requires macOS 14.4 or later.")
             }
             return MacAudioCapture(sessionID: session, generation: generation)
         }, onEvent: @escaping @Sendable (RecorderEvent) -> Void) {
        self.inputUID = inputUID
        self.source = source
        self.macCaptureFactory = macCaptureFactory
        self.onEvent = onEvent
    }

    func start(at url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            control.async {
                self.lock.lock(); let running = self.accepting; self.lock.unlock()
                guard !running else {
                    continuation.resume(throwing: LectureError.message("A recording is already running."))
                    return
                }
                do {
                    self.defaultInputReported = false
                    self.pinnedUID = self.source.usesMic ? try self.resolvedUID(self.inputUID) : nil
                    self.restartLimiter.reset()
                    guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                        throw LectureError.message("Could not create recording file.")
                    }
                    let handle = try FileHandle(forWritingTo: url)
                    self.lock.lock()
                    self.bytes = 0
                    self.queuedBytes = 0
                    self.pendingBytes = 0
                    self.failed = false
                    self.stoppedAt = nil
                    self.accepting = true
                    self.paused = false
                    self.lastMeter = 0
                    self.silenceStart = nil
                    self.silenceWarned = false
                    self.lastBuffer = Date.timeIntervalSinceReferenceDate
                    self.stalled = false
                    self.lock.unlock()
                    // The writer takes ownership before any source can deliver audio.
                    self.writer.sync {
                        self.file = handle
                        self.lastSync = ProcessInfo.processInfo.systemUptime
                    }
                    try self.startSources()
                    self.startStallTimer()
                    continuation.resume()
                } catch {
                    _ = try? self.stopOnControlQueue()
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    private static var audioTime: TimeInterval { AVAudioTime.seconds(forHostTime: mach_absolute_time()) }

    private func startSources() throws {
        lock.lock()
        let mayStart = accepting && !failed && !paused
        lock.unlock()
        guard mayStart else { return }
        guard !sourcesActive else { return }
        let generation = nextCaptureGeneration()
        lock.lock()
        if source.usesMic { micCallbackGeneration = generation }
        if source.usesMacAudio { macCallbackGeneration = generation }
        lock.unlock()
        do {
            if source.usesMacAudio {
                lock.lock()
                mixer = CaptureMixer(origin: Self.audioTime)
                mixLatency = CaptureMixer.latency
                lastRenderTime = Self.audioTime
                tapStalled = false
                lastMacSignal = Self.audioTime
                macQuietReported = false
                lock.unlock()
                try startMacAudio(generation: generation)
            }
            if source.usesMic {
                // Never leave a previous engine's tap behind: a second tap on a bus is an uncaught exception.
                if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
                if let old = engine {
                    Self.stopEngine(old, sessionID: sessionID, generation: generation,
                                    reason: "replace microphone engine", logger: logger)
                    self.engine = nil
                }
                let engine = AVAudioEngine()
                self.engine = engine
                observeMicrophoneConfiguration(engine, generation: generation)
                do {
                    try installTapAndStart(engine, generation: generation)
                } catch {
                    // A headset can change format during the first start. Preserve the
                    // previous one retry, charged to the same bounded restart budget.
                    guard restartLimiter.allowStart(at: ProcessInfo.processInfo.systemUptime) else { throw error }
                    Thread.sleep(forTimeInterval: 0.3) // Control queue only.
                    lock.lock()
                    let retry = accepting && !failed && !paused
                    lock.unlock()
                    guard retry else { stopSources(); return }
                    try installTapAndStart(engine, generation: generation)
                }
            }
            sourcesActive = true
        } catch {
            stopSources()
            throw error
        }
    }
    private func startMacAudio(generation: UInt64) throws {
        guard #available(macOS 14.4, *) else { throw LectureError.message("Mac audio requires macOS 14.4 or later.") }
        let capture = try macCaptureFactory(sessionID, generation)
        macCapture = capture
        lock.lock(); lastMacBuffer = Self.audioTime; lock.unlock()
        try capture.start { [weak self] buffer, time in self?.consumeMacAudio(buffer, time: time, generation: generation) }
        guard let format = capture.format else { throw LectureError.message("Mac audio has no input format.") }
        let converter = try CaptureConverter(format: format)
        lock.lock(); macConverter = converter; lock.unlock()
    }
    private func nextCaptureGeneration() -> UInt64 {
        captureGeneration &+= 1
        return captureGeneration
    }
    private func cancelMicrophoneRestart() {
        restartWork?.cancel()
        restartWork = nil
        restartWorkToken = nil
    }
    private func stopSources(clearConverters: Bool = true) {
        cancelMicrophoneRestart()
        let generation = nextCaptureGeneration()
        lock.lock()
        micCallbackGeneration = generation
        macCallbackGeneration = generation
        lock.unlock()
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        if let engine {
            Self.stopEngine(engine, sessionID: sessionID, generation: generation, reason: "release sources", logger: logger)
            self.engine = nil
        }
        if let capture = macCapture {
            let report = capture.stop()
            logCaptureCleanup(report, kind: "process tap cleanup", generation: generation)
            macCapture = nil
        }
        activeMicConfiguration = nil
        sourcesActive = false
        if clearConverters {
            lock.lock()
            micConverter = nil; macConverter = nil; converter = nil
            lock.unlock()
        }
    }
    private func consumeMacAudio(_ input: AVAudioPCMBuffer?, time: TimeInterval, generation: UInt64) {
        lock.lock()
        guard CaptureCallbackGate.accepts(recording: accepting, failed: failed, paused: paused,
                                          callbackGeneration: generation, currentGeneration: macCallbackGeneration) else {
            lock.unlock(); return
        }
        lastMacBuffer = Self.audioTime // Empty callbacks are also a heartbeat.
        if tapStalled {
            tapStalled = false
            if !stalled { control.async { self.onEvent(.flowing) } }
        }
        guard !paused, let input, input.frameLength > 0, let macConverter else { lock.unlock(); return }
        do {
            let samples = try macConverter.convert(input)
            if samples.contains(where: { abs($0) > 0.000001 }) {
                lastMacSignal = Self.audioTime
                if macQuietReported {
                    macQuietReported = false
                    control.async { self.onEvent(.macAudioQuiet(false)) }
                }
            }
            mixer?.push(samples, mic: false, time: time)
        }
        catch { lock.unlock(); scheduleFailure(error.localizedDescription); return }
        lock.unlock()
    }
    private func renderMacAudio(flush: Bool = false, allowStopped: Bool = false) {
        lock.lock()
        guard (accepting && !failed && !paused) || (flush && allowStopped), source.usesMacAudio else {
            lock.unlock(); return
        }
        let now = allowStopped ? (stoppedAt ?? Self.audioTime) : Self.audioTime
        // A suspended process/sleep is a gap, never minutes of synthetic silence.
        if now - lastRenderTime > 1 {
            mixer = CaptureMixer(origin: now)
            micConverter?.reset(); macConverter?.reset()
            lastBuffer = Date.timeIntervalSinceReferenceDate
            lastMacBuffer = now
        }
        lastRenderTime = now
        let deadline = now - (flush ? 0 : mixLatency)
        var samples = mixer?.render(until: deadline, both: source == .both) ?? []
        if flush {
            while let tail = mixer?.render(until: deadline, both: source == .both), !tail.isEmpty { samples += tail }
        }
        guard !samples.isEmpty else { lock.unlock(); return }
        samples.withUnsafeBufferPointer { writeLocked($0.baseAddress!, frameCount: $0.count) }
    }
    // Explicit wake recovery also handles HAL objects invalidated while asleep.
    func recoverAfterWake() {
        control.async {
            self.lock.lock()
            let active = self.accepting && !self.failed && !self.paused
            self.lock.unlock()
            guard active else { return }
            self.stallTimer?.cancel()
            self.stallTimer = nil
            self.stopSources()
            do {
                try self.startSources()
                self.startStallTimer()
            } catch { self.scheduleFailure(error.localizedDescription) }
        }
    }
    private func resolvedUID(_ uid: String?) throws -> String {
        if let uid { return uid }
        guard let device = AudioInputs.systemDefault() else {
            throw LectureError.message("No system default microphone is available.")
        }
        return device.id
    }

    private func validatedUID(_ uid: String?) throws -> String {
        guard let uid else { return try resolvedUID(nil) }
        guard AudioInputs.device(uid: uid) != nil else {
            throw LectureError.message("The selected microphone is no longer available.")
        }
        return uid
    }

    private func observeMicrophoneConfiguration(_ engine: AVAudioEngine, generation: UInt64) {
        let engineIdentity = ObjectIdentifier(engine)
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                           object: engine, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.control.async { [weak self] in
                guard let self, let current = self.engine,
                      CaptureCallbackGate.acceptsConfiguration(
                        generation: generation, currentGeneration: self.captureGeneration,
                        sameEngine: ObjectIdentifier(current) == engineIdentity) else { return }
                self.scheduleMicrophoneRestart(reason: "engine configuration changed", generation: generation)
            }
        }
    }

    private func scheduleMicrophoneRestart(reason: String, generation: UInt64) {
        guard captureGeneration == generation else { return }
        restartWork?.cancel()
        let token = UUID()
        restartWorkToken = token
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.restartWorkToken == token,
                  self.captureGeneration == generation else { return }
            self.restartWork = nil
            self.restartWorkToken = nil
            self.restartMicrophone(reason: reason, generation: generation)
        }
        restartWork = work
        control.asyncAfter(deadline: .now() + .milliseconds(200), execute: work)
    }

    private func restartMicrophone(reason: String, generation: UInt64) {
        guard captureGeneration == generation, let engine else { return }
        lock.lock()
        let shouldRestart = accepting && !failed && !paused && source.usesMic
        lock.unlock()
        guard shouldRestart else { return }
        let current = microphoneConfiguration(on: engine)
        guard !engine.isRunning || current != activeMicConfiguration else {
            logger.info("session=\(self.sessionID, privacy: .public) generation=\(generation, privacy: .public) restart=skipped reason=\(reason, privacy: .public) device_or_format_unchanged=true")
            return
        }
        guard restartLimiter.allowStart(at: ProcessInfo.processInfo.systemUptime) else {
            scheduleFailure("The microphone kept changing. The recording has been saved.")
            return
        }
        logger.info("session=\(self.sessionID, privacy: .public) generation=\(generation, privacy: .public) restart=begin reason=\(reason, privacy: .public)")
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        let next = nextCaptureGeneration()
        lock.lock(); micCallbackGeneration = next; lock.unlock()
        Self.stopEngine(engine, sessionID: sessionID, generation: next, reason: reason, logger: logger)
        do {
            try installTapAndStart(engine, generation: next)
            activeMicConfiguration = microphoneConfiguration(on: engine)
            observeMicrophoneConfiguration(engine, generation: next)
            logger.info("session=\(self.sessionID, privacy: .public) generation=\(next, privacy: .public) restart=complete reason=\(reason, privacy: .public)")
        } catch {
            logger.error("session=\(self.sessionID, privacy: .public) generation=\(next, privacy: .public) restart=failed reason=\(reason, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            scheduleMicrophoneRestart(reason: "microphone restart retry", generation: next)
        }
    }

    private func microphoneConfiguration(on engine: AVAudioEngine) -> MicrophoneConfiguration? {
        #if canImport(NosyAudioBridge)
        var error: NSError?
        guard let formats = NosyAudioFormats(engine, &error), formats.count == 2 else { return nil }
        let hardware = formats[1]
        return MicrophoneConfiguration(deviceUID: AudioInputs.current(on: engine)?.id,
                                       sampleRate: hardware.sampleRate,
                                       channels: hardware.channelCount)
        #else
        return nil
        #endif
    }

    private func installTapAndStart(_ engine: AVAudioEngine, generation: UInt64) throws {
        let defaultBefore = AudioInputs.systemDefault()?.id ?? "none"
        let inputBefore = AudioInputs.current(on: engine)?.id ?? "none"
        if try !AudioInputs.apply(uid: pinnedUID, to: engine) {
            // Re-pin the fallback as well, so subsequent default changes cannot steal it.
            guard let device = AudioInputs.current(on: engine) else {
                throw LectureError.message("No fallback microphone is available.")
            }
            pinnedUID = device.id
            if !defaultInputReported {
                defaultInputReported = true
                onEvent(.usingDefaultInput)
            }
        }
        let formatBefore = microphoneConfiguration(on: engine)
        try startTap(on: engine, generation: generation)
        guard let device = AudioInputs.current(on: engine) else {
            throw LectureError.message("Could not identify the active microphone.")
        }
        lock.lock()
        let installedRate = micRate
        let installedChannels = micChannels
        lock.unlock()
        activeMicConfiguration = MicrophoneConfiguration(deviceUID: device.id, sampleRate: installedRate, channels: installedChannels)
        let defaultAfter = AudioInputs.systemDefault()?.id ?? "none"
        logger.info("session=\(self.sessionID, privacy: .public) source=\(self.source.rawValue, privacy: .public) generation=\(generation, privacy: .public) input_uid=\(device.id, privacy: .public) transport=\(device.transport.rawValue, privacy: .public) default_before=\(defaultBefore, privacy: .public) default_after=\(defaultAfter, privacy: .public) input_before=\(inputBefore, privacy: .public) rate_before=\(formatBefore?.sampleRate ?? 0, privacy: .public) channels_before=\(formatBefore?.channels ?? 0, privacy: .public) rate_after=\(installedRate, privacy: .public) channels_after=\(installedChannels, privacy: .public)")
        onEvent(.input(name: device.name))
    }
    // Bluetooth headsets (AirPods) switch from 48 kHz A2DP to 24/16 kHz HFP when their mic opens,
    // and a node whose device was just pinned can report the previous device's format. Installing
    // a tap whose format no longer matches the hardware raises an uncaught NSException, which
    // Swift cannot catch and which aborted a real recording. So: never tap with a stale format,
    // retry a start that loses the race once, and let consume() follow each buffer's real format.
    private func startTap(on engine: AVAudioEngine, generation: UInt64) throws {
        do {
            #if canImport(NosyAudioBridge)
            var error: NSError?
            guard let formats = NosyAudioFormats(engine, &error), formats.count == 2 else {
                throw error ?? LectureError.message("The microphone has no usable input format.")
            }
            let plan = try Self.tapPlan(output: formats[0], hardware: formats[1])
            lock.lock()
            do { try configureMicLocked(plan.expected) } catch { lock.unlock(); throw error }
            lastBuffer = Date.timeIntervalSinceReferenceDate
            lock.unlock()
            guard NosyAudioStart(engine, plan.tap, { [weak self] buffer, time in
                self?.consume(buffer, time: time, generation: generation)
            }, &error) else {
                throw error ?? LectureError.message("The microphone could not start.")
            }
            #else
            // Standalone typechecks need no Clang flags. Executable builds must link the bridge.
            throw LectureError.message("Nosy's audio support is missing. Reinstall Nosy, then try again.")
            #endif
        } catch {
            Self.stopEngine(engine, sessionID: sessionID, generation: generation,
                            reason: "microphone start failed", logger: logger)
            throw error
        }
    }
    private static func stopEngine(_ engine: AVAudioEngine, sessionID: String, generation: UInt64,
                                   reason: String, logger: Logger) {
        #if canImport(NosyAudioBridge)
        var error: NSError?
        let stopped = NosyAudioStop(engine, &error)
        let status: OSStatus = stopped ? noErr : OSStatus(error?.code ?? -1)
        logger.info("session=\(sessionID, privacy: .public) generation=\(generation, privacy: .public) operation=microphone engine stop status=\(status, privacy: .public) reason=\(reason, privacy: .public)")
        #endif
    }
    // tap == nil follows the node, which survives a profile switch during installTap. When the node's
    // client format disagrees with the hardware it is stale, and only the hardware format starts.
    static func tapPlan(output: AVAudioFormat, hardware: AVAudioFormat) throws -> (tap: AVAudioFormat?, expected: AVAudioFormat) {
        func usable(_ format: AVAudioFormat) -> Bool { format.sampleRate > 0 && format.channelCount > 0 }
        guard usable(hardware) else {
            if usable(output) { return (nil, output) }
            throw LectureError.message("The microphone isn't available. Check that it's connected and that Nosy has microphone access in System Settings.")
        }
        if usable(output), output.sampleRate == hardware.sampleRate, output.channelCount == hardware.channelCount {
            return (nil, output)
        }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: hardware.sampleRate, channels: hardware.channelCount) else {
            throw LectureError.message("The selected microphone has no usable audio input.")
        }
        return (format, format)
    }
    static func micFormatChanged(rate: Double, channels: AVAudioChannelCount, to format: AVAudioFormat) -> Bool {
        format.sampleRate != rate || format.channelCount != channels
    }
    // Caller holds lock. Channels are averaged to mono by hand first: AVAudioConverter's downmix
    // drops speech on discrete multichannel interfaces (e.g. a mic on input 2 of 4).
    private func configureMicLocked(_ format: AVAudioFormat) throws {
        guard format.sampleRate > 0, format.channelCount > 0, format.commonFormat == .pcmFormatFloat32,
              let mono = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1),
              let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: mono, to: output) else {
            throw LectureError.message("The selected microphone has no usable audio input.")
        }
        micConverter = source.usesMacAudio ? try CaptureConverter(format: format) : nil
        mixLatency = max(CaptureMixer.latency, 4096 / format.sampleRate + 0.1)
        self.converter = converter
        outputFormat = output
        monoFormat = mono
        micRate = format.sampleRate
        micChannels = format.channelCount
    }
    private func startStallTimer() {
        let timer = DispatchSource.makeTimerSource(queue: control)
        let interval: DispatchTimeInterval = source.usesMacAudio ? .milliseconds(20) : .milliseconds(250)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.renderMacAudio()
            self.lock.lock()
            let notify = self.source.usesMic && self.accepting && !self.failed && !self.paused && !self.stalled
                && Date.timeIntervalSinceReferenceDate - self.lastBuffer >= 4
            if notify { self.stalled = true }
            self.lock.unlock()
            if notify { self.onEvent(.stalled) }
            let now = Self.audioTime
            if now - self.lastTapCheck >= 1, let capture = self.macCapture {
                self.lastTapCheck = now
                self.lock.lock()
                let active = self.accepting && !self.failed && !self.paused
                let last = self.lastMacBuffer
                let quiet = active && !self.macQuietReported && now - self.lastMacSignal >= 10
                if quiet { self.macQuietReported = true }
                self.lock.unlock()
                if quiet { self.onEvent(.macAudioQuiet(true)) }
                let broken = !capture.isHealthy()
                if active && (broken || CaptureWatchdog.shouldRearm(lastBuffer: last, now: now)) {
                    // A callback that never arrives cannot be distinguished from idle
                    // on every HAL driver. Re-arm quietly; only proven HAL failure warns.
                    if broken {
                        self.lock.lock(); self.tapStalled = true; self.lock.unlock()
                        self.onEvent(.stalled)
                    }
                    self.restartMacCapture(reason: broken ? "HAL unhealthy" : "reader quiet")
                }
            }
        }
        stallTimer = timer
        timer.resume()
    }
    private func consume(_ input: AVAudioPCMBuffer, time: AVAudioTime, generation: UInt64) {
        lock.lock()
        guard CaptureCallbackGate.accepts(recording: accepting, failed: failed, paused: paused,
                                          callbackGeneration: generation, currentGeneration: micCallbackGeneration) else {
            lock.unlock(); return
        }
        lastBuffer = Date.timeIntervalSinceReferenceDate
        guard !paused else { lock.unlock(); return }
        if Self.micFormatChanged(rate: micRate, channels: micChannels, to: input.format) {
            do { try configureMicLocked(input.format) }
            catch { lock.unlock(); scheduleFailure(error.localizedDescription); return }
        }
        guard let converter, let outputFormat, let monoFormat else { lock.unlock(); return }
        if stalled {
            stalled = false
            if !tapStalled { control.async { self.onEvent(.flowing) } }
        }
        if source.usesMacAudio {
            do {
                if let micConverter {
                    mixLatency = max(mixLatency, Double(input.frameLength) / input.format.sampleRate + 0.1)
                    let host = time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime)
                        : Self.audioTime - Double(input.frameLength) / input.format.sampleRate
                    mixer?.push(try micConverter.convert(input), mic: true, time: host)
                }
            } catch { lock.unlock(); scheduleFailure(error.localizedDescription); return }
            lock.unlock(); return
        }
        guard let mixed = CaptureConverter.mono(input, format: monoFormat) else {
            lock.unlock(); scheduleFailure("Could not read microphone audio."); return
        }
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * 16_000 / input.format.sampleRate)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            lock.unlock(); scheduleFailure("Could not allocate audio conversion buffer."); return
        }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if supplied { inputStatus.pointee = .noDataNow; return nil }
            supplied = true
            inputStatus.pointee = .haveData
            return mixed
        }
        if status == .error || conversionError != nil {
            lock.unlock(); scheduleFailure(conversionError?.localizedDescription ?? "Audio conversion failed."); return
        }
        let frameCount = Int(output.frameLength)
        guard frameCount > 0, let samples = output.int16ChannelData?[0] else { lock.unlock(); return }
        writeLocked(samples, frameCount: frameCount)
    }
    // Caller holds lock; always releases it, including failures. The tap never touches the file: it
    // copies the samples, updates bounded counters and queues the copy for the writer. Queuing stays
    // under the lock so writes keep capture order and stop's close follows every accepted buffer.
    // dispatch_async never waits, so the tap still never waits on disk.
    private func writeLocked(_ samples: UnsafePointer<Int16>, frameCount: Int) {
        let payloadBytes = frameCount * 2
        guard pendingBytes + payloadBytes <= Self.maxPendingBytes else {
            lock.unlock(); scheduleFailure("Could not save recording audio: the disk fell too far behind."); return
        }
        var sum = 0.0
        for index in 0..<frameCount { let value = Double(samples[index]) / 32768; sum += value * value }
        let db = max(-160, 20 * log10(max(1e-8, sqrt(sum / Double(frameCount)))))
        queuedBytes += Int64(payloadBytes)
        var notifySilence = false
        if source == .mic && db < -50 {
            if silenceStart == nil { silenceStart = queuedBytes - Int64(payloadBytes) }
            if !silenceWarned, let start = silenceStart, Core.duration(pcmBytes: queuedBytes - start) >= 60 {
                silenceWarned = true; notifySilence = true
            }
        } else { silenceStart = nil; silenceWarned = false }
        let uptime = ProcessInfo.processInfo.systemUptime
        let meter = uptime - lastMeter >= 0.1
        if meter { lastMeter = uptime }
        let silent = silenceWarned
        pendingBytes += payloadBytes
        let payload = Data(bytes: samples, count: payloadBytes)
        let meterDB: Double? = meter ? db : nil
        let silenceNotice = notifySilence
        writer.async {
            self.commitWrite(payload, meterDB: meterDB, silent: silent, notifySilence: silenceNotice)
        }
        lock.unlock()
    }
    // Writer queue only. Saved bytes and meter or silence events are published after each successful write.
    private func commitWrite(_ payload: Data, meterDB: Double?, silent: Bool, notifySilence: Bool) {
        // Release this payload exactly once, including an fsync failure after a successful write.
        defer {
            lock.lock(); pendingBytes -= payload.count; lock.unlock()
        }
        guard let file else { return }
        do {
            try file.write(contentsOf: payload)
            lock.lock()
            bytes += Int64(payload.count)
            let count = bytes
            lock.unlock()
            let uptime = ProcessInfo.processInfo.systemUptime
            if uptime - lastSync >= 5 { try file.synchronize(); lastSync = uptime }
            if let meterDB { onEvent(.level(bytes: count, db: meterDB, silent: silent)) }
            if notifySilence { onEvent(.silence) }
        } catch {
            scheduleFailure("Could not save recording audio: \(error.localizedDescription)")
        }
    }
    private func scheduleFailure(_ message: String) {
        lock.lock()
        guard !failed, accepting else { lock.unlock(); return }
        failed = true
        stoppedAt = Self.audioTime
        accepting = false
        paused = true
        pauseGeneration &+= 1
        lock.unlock()
        control.async {
            let count = (try? self.stopOnControlQueue()) ?? self.byteCount()
            self.onEvent(.failed(message, bytes: count))
        }
    }
    private func restartMacCapture(reason: String) {
        guard source.usesMacAudio, let capture = macCapture else { return }
        lock.lock()
        let active = accepting && !failed && !paused
        lock.unlock()
        guard active else { return }
        cancelMicrophoneRestart()
        let generation = nextCaptureGeneration()
        lock.lock(); macCallbackGeneration = generation; macConverter = nil; lock.unlock()
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        if let engine { observeMicrophoneConfiguration(engine, generation: generation) }
        let report = capture.stop()
        logCaptureCleanup(report, kind: "process tap rearm \(reason)", generation: generation)
        macCapture = nil
        do { try startMacAudio(generation: generation) }
        catch { scheduleFailure(error.localizedDescription) }
    }

    private func logCaptureCleanup(_ report: CaptureCleanupReport, kind: String, generation: UInt64) {
        for operation in report.operations {
            logger.info("session=\(self.sessionID, privacy: .public) generation=\(generation, privacy: .public) source=\(self.source.rawValue, privacy: .public) operation=\(kind, privacy: .public) detail=\(operation.operation, privacy: .public) status=\(operation.status, privacy: .public)")
        }
        logger.info("session=\(self.sessionID, privacy: .public) generation=\(generation, privacy: .public) source=\(self.source.rawValue, privacy: .public) operation=\(kind, privacy: .public) stop_complete=\(report.complete, privacy: .public) outstanding=\(report.outstandingResources, privacy: .public)")
    }
    // A memory-only snapshot of successful writes. Only stop drains the writer, on control.
    func byteCount() -> Int64 { lock.lock(); defer { lock.unlock() }; return bytes }

    func switchSource(_ source: RecordingSource, inputUID: String?) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            control.async {
                self.lock.lock()
                let allowed = self.accepting && !self.failed && self.paused
                let previousUID = self.pinnedUID
                self.lock.unlock()
                guard allowed, RecordingSource.available.contains(source) else {
                    continuation.resume(throwing: LectureError.message("Pause the recording before switching sources.")); return
                }
                do {
                    let pendingUID = source.usesMic ? try self.validatedUID(previousUID ?? inputUID) : previousUID
                    self.pinnedUID = pendingUID
                    self.activeMicConfiguration = nil
                    self.lock.lock()
                    self.source = source
                    self.mixer = nil
                    self.lock.unlock()
                    self.logger.info("session=\(self.sessionID, privacy: .public) generation=\(self.captureGeneration, privacy: .public) pending_source=\(source.rawValue, privacy: .public) hardware_open=false")
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func switchInput(uid: String?) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            control.async {
                self.lock.lock()
                let allowed = self.accepting && !self.failed && self.paused
                self.lock.unlock()
                guard allowed else {
                    continuation.resume(throwing: LectureError.message("Pause the recording before switching microphones."))
                    return
                }
                do {
                    self.pinnedUID = try self.validatedUID(uid)
                    self.activeMicConfiguration = nil
                    self.logger.info("session=\(self.sessionID, privacy: .public) generation=\(self.captureGeneration, privacy: .public) pending_input_uid=\(self.pinnedUID ?? "none", privacy: .public) hardware_open=false")
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func setPaused(_ paused: Bool) {
        if paused { renderMacAudio(flush: true) }
        lock.lock()
        guard accepting, !failed, self.paused != paused else { lock.unlock(); return }
        pauseGeneration &+= 1
        let token = pauseGeneration
        self.paused = paused
        // Pause already flushed its tail. Leave no empty timeline for Stop to pad with silence.
        mixer = source.usesMacAudio && !paused ? CaptureMixer(origin: Self.audioTime) : nil
        micConverter?.reset(); macConverter?.reset()
        lastRenderTime = Self.audioTime
        lastMacBuffer = Self.audioTime
        tapStalled = false
        lastMacSignal = Self.audioTime
        macQuietReported = false
        if !paused {
            silenceStart = nil
            silenceWarned = false
            lastMeter = 0
            lastBuffer = Date.timeIntervalSinceReferenceDate
            stalled = false
            converter?.reset()
        }
        lock.unlock()

        control.async {
            self.lock.lock()
            let current = self.accepting && !self.failed && self.pauseGeneration == token && self.paused == paused
            self.lock.unlock()
            guard current else { return }
            if paused {
                self.stallTimer?.cancel()
                self.stallTimer = nil
                self.stopSources()
                self.logger.info("session=\(self.sessionID, privacy: .public) generation=\(self.captureGeneration, privacy: .public) pause=true sources_stopped=true")
            } else {
                do {
                    try self.startSources()
                    if self.stallTimer == nil { self.startStallTimer() }
                    self.logger.info("session=\(self.sessionID, privacy: .public) generation=\(self.captureGeneration, privacy: .public) pause=false sources_started=true")
                } catch { self.scheduleFailure(error.localizedDescription) }
            }
        }
    }

    func stop() async throws -> Int64 {
        gateAcceptanceForStop()
        return try await withCheckedThrowingContinuation { continuation in
            control.async {
                do { continuation.resume(returning: try self.stopOnControlQueue()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
    private func gateAcceptanceForStop() {
        lock.lock()
        if accepting {
            stoppedAt = Self.audioTime
            accepting = false; paused = true; pauseGeneration &+= 1
        }
        lock.unlock()
    }
    private func stopOnControlQueue() throws -> Int64 {
        stallTimer?.cancel()
        stallTimer = nil
        cancelMicrophoneRestart()
        stopSources(clearConverters: false)
        // Drain the 200 ms jitter window before closing; no recorded tail is lost.
        renderMacAudio(flush: true, allowStopped: true)
        lock.lock()
        accepting = false
        paused = true
        converter = nil; micConverter = nil; macConverter = nil
        mixer = nil
        outputFormat = nil; monoFormat = nil
        lock.unlock()
        // The writer is serial, so this runs after every accepted buffer, then synchronizes and closes.
        try writer.sync {
            guard let handle = file else { return }
            file = nil
            defer { try? handle.close() }
            try handle.synchronize()
            try handle.close()
        }
        return byteCount()
    }
}
