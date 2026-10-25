import AVFoundation
import CoreAudio
import Foundation

struct MacAudioError: LocalizedError {
    let operation: String
    let status: OSStatus
    var permissionDenied: Bool {
        status == kAudioDevicePermissionsError || status == kAudioHardwareIllegalOperationError || status == -54
    }
    var errorDescription: String? {
        if permissionDenied {
            return "Mac audio access was denied. Enable Nosy in System Settings → Privacy & Security → Screen & System Audio Recording, then try again."
        }
        return "Could not \(operation) for Mac audio (Core Audio error \(status)). Check System Settings → Privacy & Security → Screen & System Audio Recording."
    }
}

enum CaptureWatchdog {
    static func tapStalled(alive: Bool, formatMatches: Bool, readerAttached: Bool) -> Bool {
        !alive || !formatMatches || !readerAttached
    }
    static func shouldRearm(lastBuffer: TimeInterval, now: TimeInterval) -> Bool { now - lastBuffer >= 10 }
}

protocol SystemAudioCapturing: AnyObject {
    var format: AVAudioFormat? { get }
    func start(receive: @escaping @Sendable (AVAudioPCMBuffer?, TimeInterval) -> Void) throws
    func stop()
    func isHealthy() -> Bool
}

// Lifecycle and property queries belong to Recorder.control. The IOProc only borrows
// Core Audio's input memory for the synchronous callback. No output device is opened
// for playback, and no system/default-device setting is changed.
@available(macOS 14.4, *)
final class MacAudioCapture: SystemAudioCapturing {
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private var ownProcess = AudioObjectID(kAudioObjectUnknown)
    private(set) var format: AVAudioFormat?

    func start(receive: @escaping @Sendable (AVAudioPCMBuffer?, TimeInterval) -> Void) throws {
        do {
            var pid = getpid(), size = UInt32(MemoryLayout<AudioObjectID>.size)
            var address = Self.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
            try Self.check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &ownProcess), "identify Nosy's audio process")
            guard ownProcess != kAudioObjectUnknown else {
                throw LectureError.message("Could not identify Nosy's audio process to exclude it from Mac audio.")
            }
            let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [ownProcess])
            description.name = "Nosy Mac audio"
            description.isPrivate = true
            description.muteBehavior = .unmuted
            try Self.check(AudioHardwareCreateProcessTap(description, &tap), "create a process tap")
            var asbd = AudioStreamBasicDescription()
            address = Self.address(kAudioTapPropertyFormat)
            size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try Self.check(AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd), "read the process tap format")
            guard let format = AVAudioFormat(streamDescription: &asbd), format.sampleRate > 0,
                  format.channelCount > 0, format.commonFormat == .pcmFormatFloat32 else {
                throw LectureError.message("Mac audio has no usable audio format.")
            }
            self.format = format
            let composition: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Nosy Mac audio",
                kAudioAggregateDeviceUIDKey: "com.bardya.nosy.tap.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                // Do not wait for a playing process: silent starts must return immediately.
                kAudioAggregateDeviceTapAutoStartKey: false,
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true
                ]]
            ]
            try Self.check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregate), "create the tap aggregate")
            let frameBytes = asbd.mBytesPerFrame
            try Self.check(AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregate, nil) { _, input, inputTime, _, _ in
                let time = inputTime.pointee
                let host = time.mFlags.contains(.hostTimeValid)
                    ? AVAudioTime.seconds(forHostTime: time.mHostTime) : Self.now
                // nil/empty buffers are legitimate when all tapped apps are idle.
                let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
                let expected = format.isInterleaved ? 1 : Int(format.channelCount)
                let channels = format.isInterleaved ? format.channelCount : 1
                guard buffers.count == expected,
                      frameBytes > 0,
                      buffers.allSatisfy({ $0.mData != nil && $0.mDataByteSize > 0 && $0.mNumberChannels == channels
                          && $0.mDataByteSize % frameBytes == 0 && $0.mDataByteSize == buffers[0].mDataByteSize }) else {
                    receive(nil, host); return
                }
                let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil)
                receive(buffer, host)
            }, "attach the tap reader")
            try Self.check(AudioDeviceStart(aggregate, ioProc), "start the process tap")
        } catch { stop(); throw error }
    }

    func stop() {
        if let ioProc {
            AudioDeviceStop(aggregate, ioProc)
            AudioDeviceDestroyIOProcID(aggregate, ioProc)
            self.ioProc = nil
        }
        if aggregate != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregate); aggregate = kAudioObjectUnknown }
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap); tap = kAudioObjectUnknown }
        format = nil
    }

    // Missing buffers and zero samples are both valid silence, even if another app
    // has output IO open. Only a broken HAL object/reader/format raises a warning.
    func isHealthy() -> Bool {
        guard let format else { return false }
        var asbd = AudioStreamBasicDescription(), property = Self.address(kAudioTapPropertyFormat)
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tap, &property, 0, nil, &size, &asbd)
        let original = format.streamDescription.pointee
        return !CaptureWatchdog.tapStalled(
            alive: Self.uint(kAudioDevicePropertyDeviceIsAlive, on: aggregate) == 1,
            formatMatches: status == noErr && asbd.mSampleRate == original.mSampleRate
                && asbd.mChannelsPerFrame == original.mChannelsPerFrame && asbd.mFormatFlags == original.mFormatFlags,
            readerAttached: ioProc != nil)
    }
    private static func uint(_ selector: AudioObjectPropertySelector, on object: AudioObjectID) -> UInt32? {
        var property = address(selector), value: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }
    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
    private static func check(_ status: OSStatus, _ operation: String) throws {
        if status != noErr { throw MacAudioError(operation: operation, status: status) }
    }
    static var now: TimeInterval { AVAudioTime.seconds(forHostTime: mach_absolute_time()) }
}
