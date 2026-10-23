import AVFoundation
import Foundation

enum RecorderEvent: Sendable {
    case level(bytes: Int64, db: Double, silent: Bool)
    case silence
    case usingDefaultInput
    case input(name: String)
    case stalled
    case flowing
    case failed(String, bytes: Int64)
}

// The control queue owns engine lifecycle. The lock protects converter/file state
// shared with the real-time tap; no tap callback accesses UI or MainActor state.
final class Recorder: @unchecked Sendable {
    private let control = DispatchQueue(label: "com.bardya.nosy.recorder", qos: .userInitiated)
    private let lock = NSLock()
    private let inputUID: String?
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

    init(inputUID: String? = nil, onEvent: @escaping @Sendable (RecorderEvent) -> Void) {
        self.inputUID = inputUID
        self.onEvent = onEvent
    }

    func start(at url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            control.async {
                guard self.engine == nil else {
                    continuation.resume(throwing: LectureError.message("A recording is already running."))
                    return
                }
                do {
                    self.defaultInputReported = false
                    self.pinnedUID = try self.resolvedUID(self.inputUID)
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
                    let engine = AVAudioEngine()
                    self.engine = engine
                    self.observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self = self] _ in
                        guard let self else { return }
                        self.control.async { self.restartAfterDeviceChange() }
                    }
                    try self.installTapAndStart(engine)
                    self.startStallTimer()
                    continuation.resume()
                } catch {
                    _ = try? self.stopOnControlQueue()
                    continuation.resume(throwing: error)
                }
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
        self.lock.lock()
        self.converter = converter
        self.outputFormat = output
        self.monoFormat = mono
        self.lastBuffer = Date.timeIntervalSinceReferenceDate
        self.lock.unlock()
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in self?.consume(buffer) }
        engine.prepare()
        try engine.start()
        guard let device = AudioInputs.current(on: engine) else {
            throw LectureError.message("Could not identify the active microphone.")
        }
        onEvent(.input(name: device.name))
    }
    private func startStallTimer() {
        let timer = DispatchSource.makeTimerSource(queue: control)
        timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let notify = self.accepting && !self.failed && !self.paused && !self.stalled
                && Date.timeIntervalSinceReferenceDate - self.lastBuffer >= 4
            if notify { self.stalled = true }
            self.lock.unlock()
            if notify { self.onEvent(.stalled) }
        }
        stallTimer = timer
        timer.resume()
    }
    private func consume(_ input: AVAudioPCMBuffer) {
        lock.lock()
        guard accepting, !failed else { lock.unlock(); return }
        lastBuffer = Date.timeIntervalSinceReferenceDate
        guard !paused, let converter, let outputFormat, let monoFormat, let file else { lock.unlock(); return }
        if stalled {
            stalled = false
            control.async { self.onEvent(.flowing) }
        }
        guard let mixed = Self.mixToMono(input, format: monoFormat) else {
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
        var sum = 0.0
        for index in 0..<frameCount { let value = Double(samples[index]) / 32768; sum += value * value }
        let db = max(-160, 20 * log10(max(1e-8, sqrt(sum / Double(frameCount)))))
        do {
            try file.write(contentsOf: Data(bytes: samples, count: frameCount * 2))
            bytes += Int64(frameCount * 2)
            let uptime = ProcessInfo.processInfo.systemUptime
            if uptime - lastSync >= 5 { try file.synchronize(); lastSync = uptime }
            var notifySilence = false
            if db < -50 {
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
            lock.unlock(); scheduleFailure("Could not save microphone audio: \(error.localizedDescription)")
        }
    }
    private static func mixToMono(_ input: AVAudioPCMBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = Int(input.frameLength)
        let channels = Int(input.format.channelCount)
        guard let source = input.floatChannelData,
              let mono = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: input.frameLength),
              let target = mono.floatChannelData?[0] else { return nil }
        mono.frameLength = input.frameLength
        let stride = input.stride  // 1 when deinterleaved, channel count when interleaved
        let scale = 1 / Float(channels)
        for frame in 0..<frames {
            var sum: Float = 0
            for channel in 0..<channels {
                sum += input.format.isInterleaved ? source[0][frame * stride + channel] : source[channel][frame]
            }
            target[frame] = sum * scale
        }
        return mono
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

    func switchInput(uid: String?) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            control.async {
                self.lock.lock()
                let allowed = self.accepting && !self.failed && self.paused
                self.lock.unlock()
                guard allowed, let engine = self.engine else {
                    continuation.resume(throwing: LectureError.message("Pause the recording before switching microphones."))
                    return
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
        lock.lock(); defer { lock.unlock() }
        guard self.paused != paused else { return }
        self.paused = paused
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
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        if let engine { engine.stop(); engine.inputNode.removeTap(onBus: 0); self.engine = nil }
        lock.lock(); defer { lock.unlock() }
        accepting = false
        converter = nil
        if let file {
            self.file = nil
            defer { try? file.close() }
            try file.synchronize()
            try file.close()
        }
        return bytes
    }
}
