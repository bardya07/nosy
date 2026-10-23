import AVFoundation
import Foundation

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

// The control queue owns engine lifecycle. The lock protects converter/file state
// shared with the real-time tap; no tap callback accesses UI or MainActor state.
final class Recorder: @unchecked Sendable {
    private let control = DispatchQueue(label: "com.bardya.nosy.recorder", qos: .userInitiated)
    private let lock = NSLock()
    private let inputUID: String?
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
    private var stallTimer: DispatchSourceTimer?
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?
    private var monoFormat: AVAudioFormat?
    private var file: FileHandle?
    private var bytes: Int64 = 0
    private var accepting = false
    private var paused = false
    private var failed = false
    private var lastSync: TimeInterval = 0
    private var lastMeter: TimeInterval = 0
    private var silenceStart: Int64?
    private var silenceWarned = false
    private var lastBuffer: TimeInterval = 0 // Wall-clock buffer arrival, protected by lock.
    private var stalled = false

    init(inputUID: String? = nil, source: RecordingSource = .mic, onEvent: @escaping @Sendable (RecorderEvent) -> Void) {
        self.inputUID = inputUID
        self.source = source
        self.onEvent = onEvent
    }

    func start(at url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            control.async {
                guard self.file == nil else {
                    continuation.resume(throwing: LectureError.message("A recording is already running."))
                    return
                }
                do {
                    self.defaultInputReported = false
                    self.pinnedUID = self.source.usesMic ? try self.resolvedUID(self.inputUID) : nil
                    guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                        throw LectureError.message("Could not create recording file.")
                    }
                    let handle = try FileHandle(forWritingTo: url)
                    self.lock.lock()
                    self.file = handle
                    self.bytes = 0
                    self.failed = false
                    self.accepting = true
                    self.paused = false
                    self.lastSync = ProcessInfo.processInfo.systemUptime
                    self.lastMeter = 0
                    self.silenceStart = nil
                    self.silenceWarned = false
                    self.lastBuffer = Date.timeIntervalSinceReferenceDate
                    self.stalled = false
                    self.lock.unlock()
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
        if source.usesMacAudio {
            lock.lock()
            mixer = CaptureMixer(origin: Self.audioTime)
            mixLatency = CaptureMixer.latency
            lastRenderTime = Self.audioTime
            tapStalled = false
            lastMacSignal = Self.audioTime
            macQuietReported = false
            lock.unlock()
            try startMacAudio()
        }
        if source.usesMic {
            let engine = AVAudioEngine()
            self.engine = engine
            observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
                guard let self else { return }
                self.control.async { self.restartAfterDeviceChange() }
            }
            try installTapAndStart(engine)
        }
    }
    private func startMacAudio() throws {
        guard #available(macOS 14.4, *) else { throw LectureError.message("Mac audio requires macOS 14.4 or later.") }
        let capture = MacAudioCapture()
        macCapture = capture
        lock.lock(); lastMacBuffer = Self.audioTime; lock.unlock()
        try capture.start { [weak self] buffer, time in self?.consumeMacAudio(buffer, time: time) }
        guard let format = capture.format else { throw LectureError.message("Mac audio has no input format.") }
        let converter = try CaptureConverter(format: format)
        lock.lock(); macConverter = converter; lock.unlock()
    }
    private func stopSources() {
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        if let engine { engine.stop(); engine.inputNode.removeTap(onBus: 0); self.engine = nil }
        macCapture?.stop(); macCapture = nil
        lock.lock()
        micConverter = nil; macConverter = nil; converter = nil
        lock.unlock()
    }
    private func consumeMacAudio(_ input: AVAudioPCMBuffer?, time: TimeInterval) {
        lock.lock()
        guard accepting, !failed else { lock.unlock(); return }
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
    private func renderMacAudio(flush: Bool = false) {
        lock.lock()
        guard accepting, !failed, !paused, source.usesMacAudio else { lock.unlock(); return }
        let now = Self.audioTime
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
            let active = self.accepting && !self.failed
            self.mixer = self.source.usesMacAudio ? CaptureMixer(origin: Self.audioTime) : nil
            self.lastRenderTime = Self.audioTime
            self.lastBuffer = Date.timeIntervalSinceReferenceDate
            self.lastMacBuffer = Self.audioTime
            self.lastMacSignal = Self.audioTime
            self.macQuietReported = false
            self.converter?.reset(); self.micConverter?.reset(); self.macConverter?.reset()
            self.lock.unlock()
            guard active else { return }
            self.restartAfterDeviceChange()
            if self.source.usesMacAudio {
                self.macCapture?.stop(); self.macCapture = nil
                do { try self.startMacAudio() }
                catch { self.scheduleFailure(error.localizedDescription) }
            }
        }
    }
    private func resolvedUID(_ uid: String?) throws -> String {
        if let uid { return uid }
        guard let device = AudioInputs.systemDefault() else {
            throw LectureError.message("No system default microphone is available.")
        }
        return device.id
    }
    private func installTapAndStart(_ engine: AVAudioEngine) throws {
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
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // Channels are averaged to mono by hand first: AVAudioConverter's downmix drops speech
        // on discrete multichannel interfaces (e.g. a mic on input 2 of 4).
        guard format.sampleRate > 0, format.channelCount > 0, format.commonFormat == .pcmFormatFloat32,
              let mono = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1),
              let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: mono, to: output) else {
            throw LectureError.message("The selected microphone has no usable audio input.")
        }
        let micConverter = source.usesMacAudio ? try CaptureConverter(format: format) : nil
        self.lock.lock()
        self.micConverter = micConverter
        self.mixLatency = max(CaptureMixer.latency, 4096 / format.sampleRate + 0.1)
        self.converter = converter
        self.outputFormat = output
        self.monoFormat = mono
        self.lastBuffer = Date.timeIntervalSinceReferenceDate
        self.lock.unlock()
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, time in self?.consume(buffer, time: time) }
        engine.prepare()
        try engine.start()
        guard let device = AudioInputs.current(on: engine) else {
            throw LectureError.message("Could not identify the active microphone.")
        }
        onEvent(.input(name: device.name))
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
                    capture.stop(); self.macCapture = nil
                    self.lock.lock(); self.macConverter = nil; self.lock.unlock()
                    do { try self.startMacAudio() }
                    catch { self.scheduleFailure(error.localizedDescription) }
                }
            }
        }
        stallTimer = timer
        timer.resume()
    }
    private func consume(_ input: AVAudioPCMBuffer, time: AVAudioTime) {
        lock.lock()
        guard accepting, !failed else { lock.unlock(); return }
        lastBuffer = Date.timeIntervalSinceReferenceDate
        guard !paused, let converter, let outputFormat, let monoFormat, file != nil else { lock.unlock(); return }
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
    // Always releases lock, including failures. All sources use the existing PCM writer.
    private func writeLocked(_ samples: UnsafePointer<Int16>, frameCount: Int) {
        guard let file else { lock.unlock(); return }
        var sum = 0.0
        for index in 0..<frameCount { let value = Double(samples[index]) / 32768; sum += value * value }
        let db = max(-160, 20 * log10(max(1e-8, sqrt(sum / Double(frameCount)))))
        do {
            try file.write(contentsOf: Data(bytes: samples, count: frameCount * 2))
            bytes += Int64(frameCount * 2)
            let uptime = ProcessInfo.processInfo.systemUptime
            if uptime - lastSync >= 5 { try file.synchronize(); lastSync = uptime }
            var notifySilence = false
            if source == .mic && db < -50 {
                if silenceStart == nil { silenceStart = bytes - Int64(frameCount * 2) }
                if !silenceWarned, let start = silenceStart, Core.duration(pcmBytes: bytes - start) >= 60 {
                    silenceWarned = true; notifySilence = true
                }
            } else { silenceStart = nil; silenceWarned = false }
            let meter = uptime - lastMeter >= 0.1
            if meter { lastMeter = uptime }
            let count = bytes
            let silent = silenceWarned
            lock.unlock()
            if meter { onEvent(.level(bytes: count, db: db, silent: silent)) }
            if notifySilence { onEvent(.silence) }
        } catch {
            lock.unlock(); scheduleFailure("Could not save recording audio: \(error.localizedDescription)")
        }
    }
    private func scheduleFailure(_ message: String) {
        lock.lock()
        guard !failed, accepting else { lock.unlock(); return }
        failed = true
        lock.unlock()
        control.async {
            let count = (try? self.stopOnControlQueue()) ?? self.byteCount()
            self.onEvent(.failed(message, bytes: count))
        }
    }
    private func restartAfterDeviceChange() {
        guard let engine else { return }
        lock.lock(); let active = accepting && !failed; lock.unlock()
        guard active else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        do { try installTapAndStart(engine) }
        catch { scheduleFailure("Microphone changed and could not restart: \(error.localizedDescription)") }
    }
    func byteCount() -> Int64 { lock.lock(); defer { lock.unlock() }; return bytes }

    func switchSource(_ source: RecordingSource, inputUID: String?) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            control.async {
                self.lock.lock()
                let allowed = self.accepting && !self.failed && self.paused
                let previous = self.source
                self.lock.unlock()
                guard allowed, RecordingSource.available.contains(source) else {
                    continuation.resume(throwing: LectureError.message("Pause the recording before switching sources.")); return
                }
                let previousUID = self.pinnedUID
                self.stopSources()
                do {
                    self.pinnedUID = source.usesMic ? try (previousUID ?? self.resolvedUID(inputUID)) : previousUID
                    self.lock.lock(); self.source = source; self.mixer = nil; self.lock.unlock()
                    try self.startSources()
                    self.stallTimer?.cancel()
                    self.startStallTimer()
                    continuation.resume()
                } catch {
                    self.stopSources()
                    self.pinnedUID = previousUID
                    self.lock.lock(); self.source = previous; self.mixer = nil; self.lock.unlock()
                    do {
                        try self.startSources()
                        self.stallTimer?.cancel()
                        self.startStallTimer()
                    }
                    catch { self.scheduleFailure("Could not restore the recording source: \(error.localizedDescription)") }
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
                // A paused Mac-only recording can choose its mic for a later Both switch.
                if !self.source.usesMic {
                    do { self.pinnedUID = try self.resolvedUID(uid); continuation.resume() }
                    catch { continuation.resume(throwing: error) }
                    return
                }
                guard let engine = self.engine else {
                    continuation.resume(throwing: LectureError.message("The microphone is unavailable.")); return
                }
                let previous = self.pinnedUID
                do {
                    let pinned = try self.resolvedUID(uid)
                    engine.stop()
                    engine.inputNode.removeTap(onBus: 0)
                    self.pinnedUID = pinned
                    try self.installTapAndStart(engine)
                    continuation.resume()
                } catch {
                    // Keep the lecture going on the mic that worked.
                    engine.stop()
                    engine.inputNode.removeTap(onBus: 0)
                    self.pinnedUID = previous
                    do {
                        try self.installTapAndStart(engine)
                        continuation.resume(throwing: LectureError.message("Couldn't switch to that microphone, so Nosy kept the previous one."))
                    } catch let restartError {
                        self.scheduleFailure("Could not switch microphone: \(restartError.localizedDescription)")
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    func setPaused(_ paused: Bool) {
        if paused { renderMacAudio(flush: true) }
        lock.lock(); defer { lock.unlock() }
        guard self.paused != paused else { return }
        self.paused = paused
        mixer = source.usesMacAudio ? CaptureMixer(origin: Self.audioTime) : nil
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
            // The app clears its warning on pause; start the watchdog fresh so it can warn again.
            stalled = false
            // Discard any resampler history from before the pause.
            converter?.reset()
        }
    }

    func stop() async throws -> Int64 {
        try await withCheckedThrowingContinuation { continuation in
            control.async {
                do { continuation.resume(returning: try self.stopOnControlQueue()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
    private func stopOnControlQueue() throws -> Int64 {
        stallTimer?.cancel()
        stallTimer = nil
        stopSources()
        // Drain the 200 ms jitter window before closing; no recorded tail is lost.
        renderMacAudio(flush: true)
        lock.lock(); defer { lock.unlock() }
        accepting = false
        converter = nil
        mixer = nil
        if let file {
            self.file = nil
            defer { try? file.close() }
            try file.synchronize()
            try file.close()
        }
        return bytes
    }
}
