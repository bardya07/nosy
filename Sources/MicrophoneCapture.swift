import AVFoundation
import CoreAudio
import Foundation
#if canImport(NosyAudioBridge)
import NosyAudioBridge
#endif

protocol MicrophoneCapturing: AnyObject {
    var device: AudioInputs.Device? { get }
    var format: AVAudioFormat? { get }
    func start(receive: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void,
               changed: @escaping @Sendable () -> Void) throws
    func needsRestart() -> Bool
    func stop() -> CaptureCleanupReport
}

// Lifecycle belongs to Recorder's control queue. The IOProc only reads input at
// its existing stream formats. There is no AVAudioEngine default device proxy,
// hardware format negotiation, voice processing or exclusive access.
final class MicrophoneCapture: MicrophoneCapturing {
    private let requestedUID: String?
    private let queue = DispatchQueue(label: "com.bardya.nosy.microphone-changes", qos: .userInitiated)
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var deviceID: AudioDeviceID?
    private var ioProc: AudioDeviceIOProcID?
    private var streamFormats: [AVAudioFormat] = []
    private var callback: InputCallback?
    private(set) var device: AudioInputs.Device?
    private(set) var format: AVAudioFormat?

    init(inputUID: String?) throws {
        requestedUID = inputUID
        let selected = inputUID.flatMap { AudioInputs.device(uid: $0) } ?? AudioInputs.systemDefault()
        guard let selected, let id = AudioInputs.deviceID(uid: selected.id) else {
            throw LectureError.message("No system default microphone is available.")
        }
        device = selected
        deviceID = id
        streamFormats = try Self.formats(on: id)
        guard let first = streamFormats.first,
              let output = AVAudioFormat(standardFormatWithSampleRate: first.sampleRate,
                                        channels: streamFormats.reduce(0) { $0 + $1.channelCount }) else {
            throw LectureError.message("The microphone has no usable audio input format.")
        }
        format = output
    }

    func start(receive: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void,
               changed: @escaping @Sendable () -> Void) throws {
        guard let deviceID, ioProc == nil else { throw LectureError.message("The microphone reader is unavailable.") }
        let state = InputCallback(formats: streamFormats, receive: receive, changed: changed)
        callback = state
        do {
            // Invalidate samples immediately on a physical format/layout change. The
            // recorder coalesces notices and rereads all formats before a new reader.
            try observe(deviceID, selector: kAudioDevicePropertyStreamConfiguration,
                        scope: kAudioDevicePropertyScopeInput) { state.invalidate(); changed() }
            try observe(deviceID, selector: kAudioDevicePropertyDeviceIsAlive) { state.invalidate(); changed() }
            for stream in try Self.streams(on: deviceID) {
                try observe(stream, selector: kAudioStreamPropertyVirtualFormat) { state.invalidate(); changed() }
                try observe(stream, selector: kAudioStreamPropertyPhysicalFormat) { state.invalidate(); changed() }
            }
            let system = AudioObjectID(kAudioObjectSystemObject)
            try observe(system, selector: kAudioHardwarePropertyDefaultInputDevice, action: changed)
            try observe(system, selector: kAudioHardwarePropertyDevices, action: changed)
            guard Self.sameFormats(streamFormats, try Self.formats(on: deviceID)) else {
                throw LectureError.message("The microphone changed during setup. Try recording again.")
            }
            #if canImport(NosyAudioBridge)
            var handle: AudioDeviceIOProcID?
            let status = AudioDeviceCreateIOProcIDWithBlock(&handle, deviceID, nil) { _, input, time, _, _ in
                state.consume(input, time: time.pointee)
            }
            ioProc = handle
            try Self.check(status, operation: "attach the microphone reader")
            guard let handle else { throw LectureError.message("Could not attach the microphone reader.") }
            var error: NSError?
            guard NosyMicrophoneDisableOutput(deviceID, handle, &error) else {
                throw error ?? LectureError.message("Could not open the microphone input.")
            }
            try Self.check(AudioDeviceStart(deviceID, handle), operation: "start the microphone reader")
            guard !needsRestart() else {
                throw LectureError.message("The microphone changed during setup. Try recording again.")
            }
            #else
            throw LectureError.message("Nosy's audio support is missing. Reinstall Nosy, then try again.")
            #endif
        } catch { _ = stop(); throw error }
    }

    func needsRestart() -> Bool {
        guard let deviceID, let device, callback?.valid == true else { return true }
        let target = requestedUID.flatMap { AudioInputs.device(uid: $0) } ?? AudioInputs.systemDefault()
        guard target?.id == device.id, AudioInputs.deviceID(uid: device.id) == deviceID,
              let formats = try? Self.formats(on: deviceID) else { return true }
        return !Self.sameFormats(streamFormats, formats)
    }

    @discardableResult func stop() -> CaptureCleanupReport {
        callback?.invalidate()
        for (object, property, listener) in listeners {
            var property = property
            _ = AudioObjectRemovePropertyListenerBlock(object, &property, queue, listener)
        }
        listeners.removeAll()
        var operations: [CaptureOperationStatus] = []
        if let deviceID, let ioProc {
            // Retry bounded cleanup while retaining the handle on failure. A removed
            // device already released its reader. Only this reader is stopped.
            for _ in 0..<2 {
                let stopped = AudioDeviceStop(deviceID, ioProc)
                operations.append(.init(operation: "stop microphone IO", status: stopped))
                let destroyed = AudioDeviceDestroyIOProcID(deviceID, ioProc)
                operations.append(.init(operation: "destroy microphone IOProc", status: destroyed))
                if destroyed == noErr || destroyed == kAudioHardwareBadObjectError || destroyed == kAudioHardwareBadDeviceError {
                    self.ioProc = nil
                    break
                }
            }
        }
        return CaptureCleanupReport(operations: operations, outstandingResources: ioProc == nil ? 0 : 1)
    }

    deinit { _ = stop() }

    private func observe(_ object: AudioObjectID, selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                         action: @escaping @Sendable () -> Void) throws {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        let listener: AudioObjectPropertyListenerBlock = { _, _ in action() }
        try Self.check(AudioObjectAddPropertyListenerBlock(object, &address, queue, listener), operation: "watch microphone changes")
        listeners.append((object, address, listener))
    }

    private static func streams(on device: AudioDeviceID) throws -> [AudioStreamID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                 mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size), operation: "read microphone streams")
        let stride = MemoryLayout<AudioStreamID>.stride
        guard size > 0, Int(size) % stride == 0 else { throw LectureError.message("The microphone has no input streams.") }
        var streams = [AudioStreamID](repeating: 0, count: Int(size) / stride)
        let capacity = size
        let status = streams.withUnsafeMutableBytes { AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0.baseAddress!) }
        try check(status, operation: "read microphone streams")
        guard size <= capacity, Int(size) % stride == 0 else { throw LectureError.message("The microphone input streams changed.") }
        return Array(streams.prefix(Int(size) / stride))
    }

    private static func formats(on device: AudioDeviceID) throws -> [AVAudioFormat] {
        #if canImport(NosyAudioBridge)
        var error: NSError?
        if let formats = NosyMicrophoneFormats(device, &error) { return formats }
        throw error ?? LectureError.message("Could not read the current microphone format.")
        #else
        throw LectureError.message("Nosy's audio support is missing. Reinstall Nosy, then try again.")
        #endif
    }

    private static func sameFormats(_ lhs: [AVAudioFormat], _ rhs: [AVAudioFormat]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { $0.isEqual($1) }
    }

    private static func check(_ status: OSStatus, operation: String) throws {
        guard status == noErr else { throw LectureError.message("Could not \(operation) (Core Audio error \(status)).") }
    }
}

private final class InputCallback: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private let formats: [AVAudioFormat]
    private let receive: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    private let changed: @Sendable () -> Void

    init(formats: [AVAudioFormat], receive: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void,
         changed: @escaping @Sendable () -> Void) {
        self.formats = formats; self.receive = receive; self.changed = changed
    }
    var valid: Bool { lock.lock(); defer { lock.unlock() }; return active }
    func invalidate() { lock.lock(); active = false; lock.unlock() }
    func consume(_ input: UnsafePointer<AudioBufferList>, time: AudioTimeStamp) {
        lock.lock()
        guard active else { lock.unlock(); return }
        #if canImport(NosyAudioBridge)
        var error: NSError?
        let buffer = NosyMicrophoneCopyInput(formats, input, &error)
        if buffer == nil { active = false }
        lock.unlock()
        guard let buffer else { changed(); return }
        let audioTime = time.mFlags.contains(.hostTimeValid)
            ? AVAudioTime(hostTime: time.mHostTime)
            : AVAudioTime(sampleTime: 0, atRate: buffer.format.sampleRate)
        receive(buffer, audioTime)
        #else
        lock.unlock()
        #endif
    }
}
