import AVFoundation
import CoreAudio
import Foundation

@main
enum AudioCaptureTests {
    static func main() async throws {
        func check(_ condition: Bool, _ message: String) { precondition(condition, message) }
        if CommandLine.arguments.contains("--fake-capture-only") {
            try await checkPausedCaptureLifecycle()
            try await checkDefaultMicrophoneRouting()
            print("FAKE CAPTURE PASS: default following, explicit selection, format changes, pause, wake, stale callbacks and cleanup")
            return
        }
        try await checkPausedCaptureLifecycle()
        for recording in [false, true] {
            for paused in [false, true] {
                for transitioning in [false, true] {
                    check(RecordingSource.canChange(recording: recording, paused: paused, transitioning: transitioning)
                          == (!transitioning && (!recording || paused)), "Source change state rules")
                }
            }
        }
        check(RecordingSource.restored("unknown") == .mic, "Unknown preference falls back safely")
        for source in RecordingSource.available { check(RecordingSource.restored(source.rawValue) == source, "Preference roundtrip") }
        check(RecordingSource.mic.usesMic && !RecordingSource.mic.usesMacAudio, "Mic permissions")
        check(RecordingSource.mic.modeTitle == "Room audio" && RecordingSource.mic.caption == "Records the sound around you.", "Room audio copy")
        check(RecordingSource.both.modeTitle == "Mac audio" && RecordingSource.both.caption == "Records Mac audio and your mic.", "Mac audio copy")
        check(RecordingSource.both.usesMic && RecordingSource.both.usesMacAudio, "Mac audio mode includes the microphone")
        check(!RecordingSource.macAudio.usesMic && RecordingSource.macAudio.usesMacAudio, "Mac capture needs no mic")
        check(RecordingSource.both.inputName(mic: "Pinned mic") == "Pinned mic + Mac audio", "Both source name")
        check(RecordingSource.macAudio.inputName(mic: "Ignored") == "Mac audio", "Mac source name")
        check(!CaptureWatchdog.tapStalled(alive: true, formatMatches: true, readerAttached: true), "Zero/no callbacks during silence never imply a stall")
        check(CaptureWatchdog.tapStalled(alive: false, formatMatches: true, readerAttached: true), "Dead HAL object is detected even in silence")
        check(CaptureWatchdog.tapStalled(alive: true, formatMatches: false, readerAttached: true), "Format changes trigger tap recovery")
        check(CaptureWatchdog.tapStalled(alive: true, formatMatches: true, readerAttached: false), "Lost IO reader is detected")
        check(CaptureWatchdog.shouldRearm(lastBuffer: 0, now: 10), "An unresponsive tap is rearmed without a false stall warning")
        check(!CaptureWatchdog.shouldRearm(lastBuffer: 9, now: 10), "Zero buffers count as heartbeats")
        var restartLimiter = CaptureRestartLimiter()
        check(restartLimiter.allowStart(at: 0) && restartLimiter.allowStart(at: 1)
              && restartLimiter.allowStart(at: 2) && !restartLimiter.allowStart(at: 3), "Capture restart starts are capped at three per ten seconds")
        check(restartLimiter.allowStart(at: 10), "The restart budget recovers after ten seconds")
        check(CaptureCallbackGate.accepts(recording: true, failed: false, paused: true,
                                          callbackGeneration: 7, currentGeneration: 7), "Paused sources accept no samples but may finish a heartbeat")
        check(!CaptureCallbackGate.accepts(recording: true, failed: false, paused: false,
                                           callbackGeneration: 6, currentGeneration: 7), "A stale source generation cannot resume capture")
        check(!CaptureCallbackGate.accepts(recording: false, failed: false, paused: false,
                                           callbackGeneration: 7, currentGeneration: 7), "Stop closes callback acceptance immediately")
        check(!CaptureCallbackGate.acceptsConfiguration(generation: 6, currentGeneration: 7, sameEngine: true), "Queued configuration notices from an old generation are ignored")
        check(!CaptureCallbackGate.acceptsConfiguration(generation: 7, currentGeneration: 7, sameEngine: false), "Configuration notices from a replaced engine are ignored")

        let emptyResources = CaptureResourceHandles<Int>()
        for partial in [CaptureResourceHandles<Int>(tap: 11),
                        CaptureResourceHandles<Int>(tap: 11, aggregate: 22),
                        CaptureResourceHandles<Int>(tap: 11, aggregate: 22, ioProc: 33)] {
            var handles = partial
            let fake = FakeCaptureResourceAdapter()
            _ = handles.release(using: fake)
            check(handles.count == 0, "Partial capture construction releases every acquired object")
        }
        var failedCleanup = CaptureResourceHandles<Int>(tap: 11, aggregate: 22, ioProc: 33)
        let retryAdapter = FakeCaptureResourceAdapter()
        retryAdapter.queue(["stop IO": [-1, noErr], "destroy IOProc": [-1, noErr],
                            "destroy aggregate": [-1, noErr], "destroy tap": [-1, noErr]])
        let firstCleanup = failedCleanup.release(using: retryAdapter)
        check(firstCleanup.operations.count == 4 && firstCleanup.outstandingResources == 3,
              "Cleanup continues after failures and retains live resource identities")
        let secondCleanup = failedCleanup.release(using: retryAdapter)
        check(secondCleanup.complete && failedCleanup.count == 0, "A bounded fake HAL retry releases remaining capture resources")
        check(retryAdapter.calls == ["stop IO", "destroy IOProc", "destroy aggregate", "destroy tap",
                                     "stop IO", "destroy IOProc", "destroy aggregate", "destroy tap"],
              "Cleanup uses the required stop and destruction order")
        var missingObjects = CaptureResourceHandles<Int>(tap: 11, aggregate: 22, ioProc: 33)
        let missingAdapter = FakeCaptureResourceAdapter(defaultStatus: kAudioHardwareBadObjectError)
        check(missingObjects.release(using: missingAdapter).complete, "Already missing HAL objects count as released")
        _ = emptyResources

        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let captureSource = try String(contentsOf: root.appendingPathComponent("Sources/MacAudioCapture.swift"), encoding: .utf8)
        let inputSource = try String(contentsOf: root.appendingPathComponent("Sources/AudioInputs.swift"), encoding: .utf8)
        check(!captureSource.contains("AudioObjectSetPropertyData"), "Process capture never writes global device defaults")
        check(!captureSource.contains("kAudioDevicePropertyHogMode") && !captureSource.contains("setVoiceProcessingEnabled"), "Process capture never requests hog mode or voice processing")
        check(!inputSource.contains("AudioObjectSetPropertyData") && !inputSource.contains("AudioUnitSetProperty"), "Input enumeration never configures devices or audio units")
        if #available(macOS 14.4, *) {
            let tap = MacAudioCapture.tapDescription(excluding: 42)
            check(tap.isPrivate && tap.muteBehavior == .unmuted, "The process tap stays private and unmuted")
            let tapID = UUID()
            let composition = MacAudioCapture.aggregateComposition(tapUUID: tapID)
            let tapList = composition[kAudioAggregateDeviceTapListKey] as? [[String: Any]]
            check(composition[kAudioAggregateDeviceIsPrivateKey] as? Bool == true
                  && (composition[kAudioAggregateDeviceUIDKey] as? String)?.hasPrefix("com.bardya.nosy.tap.") == true,
                  "The tap aggregate stays private and receives a unique Nosy identity")
            check(tapList?.first?[kAudioSubTapUIDKey] as? String == tapID.uuidString,
                  "The aggregate contains the process tap without physical subdevices")
        }
        check(MacAudioError(operation: "start", status: kAudioHardwareIllegalOperationError).permissionDenied, "Permission error mapping")
        let idle = Recorder { _ in }
        do { try await idle.switchSource(.macAudio, inputUID: nil); preconditionFailure("Idle recorder cannot switch live hardware") }
        catch { check(error.localizedDescription.contains("Pause"), "Recorder enforces source rules") }

        // AirPods formats are consumed as delivered, with conversion inside Nosy.
        let hfp = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
        check(Recorder.micFormatChanged(rate: 48_000, channels: 1, to: hfp), "A 48 to 24 kHz buffer rebuilds the converters")
        check(!Recorder.micFormatChanged(rate: 24_000, channels: 1, to: hfp), "Same format buffers keep the converter state")

        for interleaved in [false, true] {
            let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 4)!
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, interleaved: interleaved, channelLayout: layout)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
            buffer.frameLength = 480
            for frame in 0..<480 {
                for channel in 0..<4 {
                    let value: Float = channel == 1 ? 0.8 : 0
                    if interleaved { buffer.floatChannelData![0][frame * 4 + channel] = value }
                    else { buffer.floatChannelData![channel][frame] = value }
                }
            }
            let monoFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
            let mono = CaptureConverter.mono(buffer, format: monoFormat)!
            check(abs(mono.floatChannelData![0][100] - 0.2) < 0.00001, "Downmix preserves speech on discrete channel 2")
        }
        for rate in [44_100.0, 48_000.0, 96_000.0] {
            let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
            let converter = try CaptureConverter(format: format)
            let frames = Int(rate / 100)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
            buffer.frameLength = AVAudioFrameCount(frames)
            var result: [Float] = []
            for block in 0..<100 {
                for frame in 0..<frames {
                    let value = Float(sin(2 * Double.pi * 440 * Double(block * frames + frame) / rate)) * 0.25
                    buffer.floatChannelData![0][frame] = value; buffer.floatChannelData![1][frame] = value
                }
                result += try converter.convert(buffer)
            }
            check(abs(result.count - 16_000) <= 64, "Streaming rate conversion preserves duration at \(rate)")
            let rms = sqrt(result.dropFirst(160).reduce(0.0) { $0 + Double($1 * $1) } / Double(result.count - 160))
            check(abs(rms - 0.25 / sqrt(2)) < 0.005, "Resampling preserves speech-band level")
            converter.reset()
            for channel in 0..<2 { buffer.floatChannelData![channel].initialize(repeating: 0, count: frames) }
            check(try converter.convert(buffer).allSatisfy { abs($0) < 0.00001 }, "Reset discards pre-pause history")
        }
        let aliasFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let aliasConverter = try CaptureConverter(format: aliasFormat)
        let aliasBuffer = AVAudioPCMBuffer(pcmFormat: aliasFormat, frameCapacity: 480)!
        aliasBuffer.frameLength = 480
        var aliasSamples: [Float] = []
        for block in 0..<100 {
            for frame in 0..<480 {
                aliasBuffer.floatChannelData![0][frame] = Float(sin(2 * Double.pi * 12_000 * Double(block * 480 + frame) / 48_000)) * 0.5
            }
            aliasSamples += try aliasConverter.convert(aliasBuffer)
        }
        let aliasPower = aliasSamples.dropFirst(160).reduce(0.0) { $0 + Double($1 * $1) } / Double(aliasSamples.count - 160)
        check(sqrt(aliasPower) < 0.005, "Resampling filters frequencies above the 16 kHz Nyquist limit")
        var aligned = CaptureMixer(origin: 0)
        aligned.push([Float](repeating: 0.2, count: 1600), mic: false, time: 0)
        aligned.push([Float](repeating: -0.2, count: 1600), mic: true, time: 0)
        check(aligned.render(until: 0.1, both: true).allSatisfy { $0 == 0 }, "Opposite sources align on the same host timeline")
        // No source buffers at all: valid PCM zeros and exact wall-clock duration.
        var silent = CaptureMixer(origin: 100)
        var silence: [Int16] = []
        for index in 1...20 { silence += silent.render(until: 100 + Double(index) / 4, both: false) }
        check(silence.count == 80_000 && silence.allSatisfy { $0 == 0 }, "Five seconds of idle tap is valid silent PCM")
        var balance = CaptureBalance()
        var loud: [Int16] = [], quiet: [Int16] = []
        for i in 0..<64_000 {
            let wave = Float(sin(2 * Double.pi * 440 * Double(i) / 16_000))
            let value = balance.mix(mic: wave * 0.05, mac: wave * 0.8, both: true)
            check(abs(Int(value)) < 32767, "Mixed peaks never clip")
            if i >= 48_000 { loud.append(value) }
        }
        for i in 0..<16_000 {
            let wave = Float(sin(2 * Double.pi * 440 * Double(i) / 16_000))
            quiet.append(balance.mix(mic: wave * 0.05, mac: 0, both: true))
        }
        let rms: ([Int16]) -> Double = { values in sqrt(values.reduce(0) { $0 + pow(Double($1), 2) } / Double(values.count)) }
        check(rms(loud) / rms(quiet) < 3, "Quiet microphone remains audible beside loud Mac audio")
        for value: Float in [0, 1, -1, 10, -10, .nan, .infinity] {
            check(abs(Int(balance.mix(mic: value, mac: value, both: true))) < 32767, "Limiter handles peaks/nonfinite input")
        }
        // One minute of independent clock drift at an exaggerated 0.5%.
        // Buffers are reanchored to host time, never queued into a growing backlog.
        var drift = CaptureMixer(origin: 0)
        var outputCount = 0, nonzero = 0
        for block in 0..<6000 {
            let time = Double(block) * 0.01005
            drift.push([Float](repeating: 0.1, count: 160), mic: false, time: time)
            let result = drift.render(until: max(0, time - 0.2), both: false)
            outputCount += result.count; nonzero += result.filter { $0 != 0 }.count
        }
        check(abs(Double(outputCount) / 16_000 - (Double(5999) * 0.01005 - 0.2)) < 0.001, "Output follows host clock despite drift")
        check(Double(nonzero) / Double(outputCount) > 0.999, "Drift correction does not leave periodic holes")
        var tail = CaptureMixer(origin: 0)
        tail.push([Float](repeating: 0.25, count: 1600), mic: false, time: 0)
        let tailOutput = tail.render(until: 0.05, both: false)
        check(tailOutput.count == 800 && tailOutput.allSatisfy { $0 > 0 }, "Stop flush retains a partially captured final buffer")
        var track = CaptureTrack()
        track.push([0.5, 0.5], at: 0, cursor: 40_000)
        track.push([0.5, 0.5], at: 2, cursor: 40_000)
        check(track.sample(at: 40_000) == 0, "Late buffers cannot replay after a gap")
        print("AUDIO CAPTURE UNIT PASS: source rules, channels, streaming resampling, silence, balance, limiter, drift and late buffers")
    }

    // These factories never enumerate devices, create an engine or register real IO.
    static func checkDefaultMicrophoneRouting() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Nosy-fake-mics-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for source in [RecordingSource.mic, .both] {
            let routing = FakeMicrophoneRouting()
            let counts = FakeCaptureCounts()
            let recorder = Recorder(source: source, microphoneFactory: { routing.make(inputUID: $0) },
                                    macCaptureFactory: { _, _ in FakeSystemAudioCapture(counts: counts) }) { _ in }
            try await recorder.start(at: directory.appendingPathComponent("\(source.rawValue).pcm"))
            precondition(routing.started == ["default A:24000"], "Start uses the existing 24 kHz default in either mode")
            routing.changeDefault(to: "default B", rate: 48_000)
            try await Task.sleep(for: .milliseconds(300))
            precondition(routing.started == ["default A:24000", "default B:48000"], "The running mic follows a new default")
            routing.deliverObsoleteCallback()
            recorder.setPaused(true)
            try await Task.sleep(for: .milliseconds(60))
            try await recorder.switchInput(uid: "chosen mic")
            recorder.setPaused(false)
            try await Task.sleep(for: .milliseconds(60))
            precondition(routing.started.last == "chosen mic:24000", "An explicit choice opens at its current format")
            let explicitCount = routing.started.count
            routing.changeDefault(to: "default C", rate: 44_100)
            try await Task.sleep(for: .milliseconds(300))
            precondition(routing.started.count == explicitCount, "Default changes never replace an explicit mic")
            recorder.setPaused(true)
            try await Task.sleep(for: .milliseconds(60))
            try await recorder.switchInput(uid: nil)
            if RecordingSource.available.contains(.both) { try await recorder.switchSource(.both, inputUID: nil) }
            recorder.setPaused(false)
            try await Task.sleep(for: .milliseconds(60))
            precondition(routing.started.last == "default C:44100", "Selecting system default restores following across mode changes")
            routing.changeDefault(to: "default C", rate: 24_000)
            try await Task.sleep(for: .milliseconds(300))
            precondition(routing.started.last == "default C:24000", "A live format change rebuilds the reader at the new rate")
            _ = try await recorder.stop()
            precondition(routing.activeCount == 0, "Stop releases every fake mic")
            let pcm = try Data(contentsOf: directory.appendingPathComponent("\(source.rawValue).pcm"))
            precondition(pcm.allSatisfy { $0 == 0 }, "Old mic callbacks cannot append samples after a restart")
        }
    }

    // Real Recorder control/writer queues, with no HAL tap, engine, or real audio.
    static func checkPausedCaptureLifecycle() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Nosy-fake-capture-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let counts = FakeCaptureCounts()
        let recorder = Recorder(source: .macAudio, macCaptureFactory: { _, _ in
            FakeSystemAudioCapture(counts: counts)
        }) { _ in }
        try await recorder.start(at: directory.appendingPathComponent("paused.pcm"))
        try await Task.sleep(for: .milliseconds(120))
        recorder.setPaused(true)
        try await Task.sleep(for: .milliseconds(80))
        let pausedBytes = recorder.byteCount()
        precondition(counts.snapshot == [1, 1, 0], "Pause releases the only fake capture")
        recorder.recoverAfterWake()
        try await Task.sleep(for: .milliseconds(120))
        precondition(counts.snapshot == [1, 1, 0], "Wake never opens a paused capture")
        let stoppedBytes = try await recorder.stop()
        precondition(stoppedBytes == pausedBytes, "Stopping while paused never appends silent padding")

        let resumed = Recorder(source: .macAudio, macCaptureFactory: { _, _ in
            FakeSystemAudioCapture(counts: counts)
        }) { _ in }
        try await resumed.start(at: directory.appendingPathComponent("resumed.pcm"))
        resumed.setPaused(true)
        try await Task.sleep(for: .milliseconds(60))
        resumed.setPaused(false)
        try await Task.sleep(for: .milliseconds(60))
        precondition(counts.snapshot == [3, 2, 1], "Resume creates exactly one fresh capture")
        counts.deliver(to: 1) // The resumed recorder's obsolete source, before Pause.
        try await Task.sleep(for: .milliseconds(30))
        _ = try await resumed.stop()
        precondition(counts.snapshot == [3, 3, 0], "Stop releases the resumed capture")
        let resumedPCM = try Data(contentsOf: directory.appendingPathComponent("resumed.pcm"))
        precondition(resumedPCM.allSatisfy { $0 == 0 }, "Obsolete source callbacks never enter the resumed timeline")

        let delayed = Recorder(source: .macAudio, macCaptureFactory: { _, _ in
            FakeSystemAudioCapture(counts: counts, stopDelay: 0.2)
        }) { _ in }
        let started = ProcessInfo.processInfo.systemUptime
        try await delayed.start(at: directory.appendingPathComponent("slow-stop.pcm"))
        try await Task.sleep(for: .milliseconds(100))
        let requestedDuration = ProcessInfo.processInfo.systemUptime - started
        let finalBytes = try await delayed.stop()
        precondition(Core.duration(pcmBytes: finalBytes) <= requestedDuration + 0.05,
                     "HAL teardown time never extends the saved timeline")
        precondition(counts.snapshot == [4, 4, 0], "No fake source survives a terminal path")

        let failed = Recorder(source: .macAudio, macCaptureFactory: { _, _ in
            FakeSystemAudioCapture(counts: counts, failStart: true)
        }) { _ in }
        do {
            try await failed.start(at: directory.appendingPathComponent("failed.pcm"))
            preconditionFailure("The fake source must fail startup")
        } catch {
            precondition(counts.snapshot == [5, 5, 0], "A partially started source is released on failure")
        }
    }
}

private final class FakeCaptureCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0, stops = 0, active = 0
    private var receivers: [@Sendable (AVAudioPCMBuffer?, TimeInterval) -> Void] = []
    var snapshot: [Int] { lock.lock(); defer { lock.unlock() }; return [starts, stops, active] }
    func start(_ receive: @escaping @Sendable (AVAudioPCMBuffer?, TimeInterval) -> Void) {
        lock.lock(); defer { lock.unlock() }; starts += 1; active += 1; receivers.append(receive)
    }
    func stop() { lock.lock(); defer { lock.unlock() }; stops += 1; active -= 1 }
    func deliver(to index: Int) {
        lock.lock(); let receive = receivers[index]; lock.unlock()
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
        buffer.frameLength = 160
        buffer.floatChannelData![0].initialize(repeating: 0.25, count: 160)
        receive(buffer, AVAudioTime.seconds(forHostTime: mach_absolute_time()))
    }
}

private final class FakeSystemAudioCapture: SystemAudioCapturing {
    let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)
    private let counts: FakeCaptureCounts
    private let stopDelay: TimeInterval
    private let failStart: Bool
    private var stopped = false
    init(counts: FakeCaptureCounts, stopDelay: TimeInterval = 0, failStart: Bool = false) {
        self.counts = counts
        self.stopDelay = stopDelay
        self.failStart = failStart
    }
    func start(receive: @escaping @Sendable (AVAudioPCMBuffer?, TimeInterval) -> Void) throws {
        counts.start(receive)
        if failStart { throw LectureError.message("Fake source startup failed.") }
    }
    func stop() -> CaptureCleanupReport {
        if !stopped {
            stopped = true
            if stopDelay > 0 { Thread.sleep(forTimeInterval: stopDelay) }
            counts.stop()
        }
        return CaptureCleanupReport(operations: [], outstandingResources: 0)
    }
    func isHealthy() -> Bool { !stopped }
}

private final class FakeCaptureResourceAdapter: CaptureResourceAdapter {
    typealias IOProc = Int
    private(set) var calls: [String] = []
    private var statusQueues: [String: [OSStatus]] = [:]
    private let defaultStatus: OSStatus

    init(defaultStatus: OSStatus = noErr) { self.defaultStatus = defaultStatus }

    func queue(_ values: [String: [OSStatus]]) { statusQueues = values }
    func stopIO(aggregate: AudioObjectID, ioProc: Int) -> OSStatus { result("stop IO") }
    func destroyIOProc(aggregate: AudioObjectID, ioProc: Int) -> OSStatus { result("destroy IOProc") }
    func destroyAggregate(_ aggregate: AudioObjectID) -> OSStatus { result("destroy aggregate") }
    func destroyTap(_ tap: AudioObjectID) -> OSStatus { result("destroy tap") }

    private func result(_ operation: String) -> OSStatus {
        calls.append(operation)
        guard var queue = statusQueues[operation], !queue.isEmpty else { return defaultStatus }
        let value = queue.removeFirst()
        statusQueues[operation] = queue
        return value
    }
}

private final class FakeMicrophoneRouting: @unchecked Sendable {
    private let lock = NSLock()
    private var defaultUID = "default A"
    private var rate = 24_000.0
    private var readers: [FakeMicrophone] = []
    private var history: [String] = []
    var started: [String] { lock.lock(); defer { lock.unlock() }; return history }
    var activeCount: Int { lock.lock(); defer { lock.unlock() }; return readers.filter { $0.active }.count }
    func make(inputUID: String?) -> FakeMicrophone {
        lock.lock(); defer { lock.unlock() }
        let mic = FakeMicrophone(routing: self, requested: inputUID, uid: inputUID ?? defaultUID,
                                 rate: inputUID == nil ? rate : 24_000)
        readers.append(mic)
        return mic
    }
    func recordStart(_ mic: FakeMicrophone) {
        lock.lock(); defer { lock.unlock() }
        history.append("\(mic.device!.id):\(Int(mic.format!.sampleRate))")
    }
    func matches(_ mic: FakeMicrophone) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return mic.device?.id == (mic.requested ?? defaultUID) && mic.format?.sampleRate == (mic.requested == nil ? rate : 24_000)
    }
    func changeDefault(to uid: String, rate: Double) {
        lock.lock()
        defaultUID = uid; self.rate = rate
        let callbacks = readers.filter { $0.active }.compactMap { $0.changed }
        lock.unlock()
        callbacks.forEach { $0() }
    }
    func deliverObsoleteCallback() {
        lock.lock(); let receive = readers.first?.receive; lock.unlock()
        let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 240)!
        buffer.frameLength = 240
        buffer.floatChannelData![0].initialize(repeating: 0.5, count: 240)
        receive?(buffer, AVAudioTime(hostTime: mach_absolute_time()))
    }
}

private final class FakeMicrophone: MicrophoneCapturing {
    private let routing: FakeMicrophoneRouting
    let requested: String?
    let device: AudioInputs.Device?
    let format: AVAudioFormat?
    var active = false
    var receive: (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)?
    var changed: (@Sendable () -> Void)?
    init(routing: FakeMicrophoneRouting, requested: String?, uid: String, rate: Double) {
        self.routing = routing; self.requested = requested
        device = .init(id: uid, name: uid)
        format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)
    }
    func start(receive: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void,
               changed: @escaping @Sendable () -> Void) throws {
        self.receive = receive; self.changed = changed; active = true
        routing.recordStart(self)
    }
    func needsRestart() -> Bool { !routing.matches(self) }
    func stop() -> CaptureCleanupReport {
        active = false
        return CaptureCleanupReport(operations: [], outstandingResources: 0)
    }
}
