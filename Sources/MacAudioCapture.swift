import AVFoundation
import CoreAudio
import Foundation
import os

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

struct CaptureOperationStatus: Equatable, Sendable {
    let operation: String
    let status: OSStatus
    let tap: AudioObjectID?
    let aggregate: AudioObjectID?

    init(operation: String, status: OSStatus, tap: AudioObjectID? = nil, aggregate: AudioObjectID? = nil) {
        self.operation = operation
        self.status = status
        self.tap = tap
        self.aggregate = aggregate
    }
}

struct CaptureCleanupReport: Equatable, Sendable {
    var operations: [CaptureOperationStatus]
    let outstandingResources: Int
    var complete: Bool { outstandingResources == 0 }

    func appending(_ other: CaptureCleanupReport) -> CaptureCleanupReport {
        CaptureCleanupReport(operations: operations + other.operations,
                             outstandingResources: other.outstandingResources)
    }
}

protocol CaptureResourceAdapter {
    associatedtype IOProc
    func stopIO(aggregate: AudioObjectID, ioProc: IOProc) -> OSStatus
    func destroyIOProc(aggregate: AudioObjectID, ioProc: IOProc) -> OSStatus
    func destroyAggregate(_ aggregate: AudioObjectID) -> OSStatus
    func destroyTap(_ tap: AudioObjectID) -> OSStatus
}

struct CaptureResourceHandles<IOProc> {
    var tap: AudioObjectID?
    var aggregate: AudioObjectID?
    var ioProc: IOProc?

    var count: Int { (tap == nil ? 0 : 1) + (aggregate == nil ? 0 : 1) + (ioProc == nil ? 0 : 1) }

    mutating func release<Adapter: CaptureResourceAdapter>(using adapter: Adapter) -> CaptureCleanupReport
    where Adapter.IOProc == IOProc {
        var operations: [CaptureOperationStatus] = []
        if let ioProc, let aggregate {
            let stop = adapter.stopIO(aggregate: aggregate, ioProc: ioProc)
            operations.append(CaptureOperationStatus(operation: "stop IO", status: stop,
                                                     tap: tap, aggregate: aggregate))
            let destroy = adapter.destroyIOProc(aggregate: aggregate, ioProc: ioProc)
            operations.append(CaptureOperationStatus(operation: "destroy IOProc", status: destroy,
                                                     tap: tap, aggregate: aggregate))
            if CaptureResourceHandles.isReleased(destroy) { self.ioProc = nil }
        } else if aggregate == nil {
            ioProc = nil
        }
        if let aggregate {
            let status = adapter.destroyAggregate(aggregate)
            operations.append(CaptureOperationStatus(operation: "destroy aggregate", status: status,
                                                     tap: tap, aggregate: aggregate))
            if CaptureResourceHandles.isReleased(status) {
                self.aggregate = nil
                // Destroying the owning device also releases any remaining IOProc.
                self.ioProc = nil
            }
        }
        if let tap {
            let status = adapter.destroyTap(tap)
            operations.append(CaptureOperationStatus(operation: "destroy tap", status: status,
                                                     tap: tap, aggregate: aggregate))
            if CaptureResourceHandles.isReleased(status) { self.tap = nil }
        }
        return CaptureCleanupReport(operations: operations, outstandingResources: count)
    }

    private static func isReleased(_ status: OSStatus) -> Bool {
        status == noErr || status == kAudioHardwareBadObjectError || status == kAudioHardwareBadDeviceError
    }
}

protocol SystemAudioCapturing: AnyObject {
    var format: AVAudioFormat? { get }
    func start(receive: @escaping @Sendable (AVAudioPCMBuffer?, TimeInterval) -> Void) throws
    func stop() -> CaptureCleanupReport
    func isHealthy() -> Bool
}

@available(macOS 14.4, *)
private struct CoreAudioCaptureResourceAdapter: CaptureResourceAdapter {
    func stopIO(aggregate: AudioObjectID, ioProc: AudioDeviceIOProcID) -> OSStatus {
        AudioDeviceStop(aggregate, ioProc)
    }
    func destroyIOProc(aggregate: AudioObjectID, ioProc: AudioDeviceIOProcID) -> OSStatus {
        AudioDeviceDestroyIOProcID(aggregate, ioProc)
    }
    func destroyAggregate(_ aggregate: AudioObjectID) -> OSStatus {
        AudioHardwareDestroyAggregateDevice(aggregate)
    }
    func destroyTap(_ tap: AudioObjectID) -> OSStatus { AudioHardwareDestroyProcessTap(tap) }
}

// Lifecycle and property queries belong to Recorder.control. The IOProc only borrows
// Core Audio's input memory for the synchronous callback. No output device is opened
// for playback, and no system/default-device setting is changed.
@available(macOS 14.4, *)
final class MacAudioCapture: SystemAudioCapturing {
    private var resources = CaptureResourceHandles<AudioDeviceIOProcID>()
    private let sessionID: String
    private let logger = Logger(subsystem: "com.bardya.nosy", category: "AudioCapture")
    private var stopAttempted = false
    private var ownProcess = AudioObjectID(kAudioObjectUnknown)
    private let generation: UInt64
    private(set) var format: AVAudioFormat?

    init(sessionID: String, generation: UInt64) {
        self.sessionID = sessionID
        self.generation = generation
    }
    var tapIdentity: AudioObjectID? { resources.tap }
    var aggregateIdentity: AudioObjectID? { resources.aggregate }

    deinit {
        guard resources.count > 0 else { return }
        stopAttempted = true
        log(cleanup())
    }

    func start(receive: @escaping @Sendable (AVAudioPCMBuffer?, TimeInterval) -> Void) throws {
        do {
            var pid = getpid(), size = UInt32(MemoryLayout<AudioObjectID>.size)
            var address = Self.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
            try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &ownProcess), "identify Nosy's audio process")
            guard ownProcess != kAudioObjectUnknown else {
                throw LectureError.message("Could not identify Nosy's audio process to exclude it from Mac audio.")
            }
            let description = Self.tapDescription(excluding: ownProcess)
            var tap = AudioObjectID(kAudioObjectUnknown)
            let tapStatus = AudioHardwareCreateProcessTap(description, &tap)
            if tap != kAudioObjectUnknown { resources.tap = tap }
            try check(tapStatus, "create a process tap")
            var asbd = AudioStreamBasicDescription()
            address = Self.address(kAudioTapPropertyFormat)
            size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try check(AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd), "read the process tap format")
            guard let format = AVAudioFormat(streamDescription: &asbd), format.sampleRate > 0,
                  format.channelCount > 0, format.commonFormat == .pcmFormatFloat32 else {
                throw LectureError.message("Mac audio has no usable audio format.")
            }
            self.format = format
            logger.info("session=\(self.sessionID, privacy: .public) generation=\(self.generation, privacy: .public) operation=read process tap format rate=\(format.sampleRate, privacy: .public) channels=\(format.channelCount, privacy: .public) tap=\(self.resources.tap ?? 0, privacy: .public)")
            let composition = Self.aggregateComposition(tapUUID: description.uuid)
            var aggregate = AudioObjectID(kAudioObjectUnknown)
            let aggregateStatus = AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregate)
            if aggregate != kAudioObjectUnknown { resources.aggregate = aggregate }
            try check(aggregateStatus, "create the tap aggregate")
            let frameBytes = asbd.mBytesPerFrame
            var ioProc: AudioDeviceIOProcID?
            let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregate, nil) { _, input, inputTime, _, _ in
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
            }
            if let ioProc { resources.ioProc = ioProc }
            try check(ioStatus, "attach the tap reader")
            guard let ioProc else { throw LectureError.message("Could not attach the Mac audio reader.") }
            try check(AudioDeviceStart(aggregate, ioProc), "start the process tap")
        } catch { _ = stop(); throw error }
    }

    @discardableResult func stop() -> CaptureCleanupReport {
        guard !stopAttempted else {
            let report = CaptureCleanupReport(operations: [], outstandingResources: resources.count)
            log(report)
            return report
        }
        stopAttempted = true
        var report = cleanup()
        if resources.count > 0 {
            report = report.appending(cleanup())
        }
        format = nil
        log(report)
        return report
    }

    private func cleanup() -> CaptureCleanupReport {
        resources.release(using: CoreAudioCaptureResourceAdapter())
    }

    // Missing buffers and zero samples are both valid silence, even if another app
    // has output IO open. Only a broken HAL object/reader/format raises a warning.
    func isHealthy() -> Bool {
        guard let format else { return false }
        guard let tap = resources.tap, let aggregate = resources.aggregate, resources.ioProc != nil else { return false }
        var asbd = AudioStreamBasicDescription(), property = Self.address(kAudioTapPropertyFormat)
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tap, &property, 0, nil, &size, &asbd)
        let original = format.streamDescription.pointee
        return !CaptureWatchdog.tapStalled(
            alive: Self.uint(kAudioDevicePropertyDeviceIsAlive, on: aggregate) == 1,
            formatMatches: status == noErr && asbd.mSampleRate == original.mSampleRate
                && asbd.mChannelsPerFrame == original.mChannelsPerFrame && asbd.mFormatFlags == original.mFormatFlags,
            readerAttached: resources.ioProc != nil)
    }
    private static func uint(_ selector: AudioObjectPropertySelector, on object: AudioObjectID) -> UInt32? {
        var property = address(selector), value: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }
    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
    private func check(_ status: OSStatus, _ operation: String) throws {
        logger.info("session=\(self.sessionID, privacy: .public) generation=\(self.generation, privacy: .public) operation=\(operation, privacy: .public) status=\(status, privacy: .public) tap=\(self.resources.tap ?? 0, privacy: .public) aggregate=\(self.resources.aggregate ?? 0, privacy: .public)")
        if status != noErr { throw MacAudioError(operation: operation, status: status) }
    }
    private func log(_ report: CaptureCleanupReport) {
        for operation in report.operations {
            logger.info("session=\(self.sessionID, privacy: .public) generation=\(self.generation, privacy: .public) operation=\(operation.operation, privacy: .public) status=\(operation.status, privacy: .public) tap=\(operation.tap ?? 0, privacy: .public) aggregate=\(operation.aggregate ?? 0, privacy: .public)")
        }
        logger.info("session=\(self.sessionID, privacy: .public) generation=\(self.generation, privacy: .public) stop_complete=\(report.complete, privacy: .public) outstanding=\(report.outstandingResources, privacy: .public)")
    }
    static func tapDescription(excluding process: AudioObjectID) -> CATapDescription {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [process])
        description.name = "Nosy Mac audio"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        return description
    }
    static func aggregateComposition(tapUUID: UUID) -> [String: Any] {
        [
            kAudioAggregateDeviceNameKey: "Nosy Mac audio",
            kAudioAggregateDeviceUIDKey: "com.bardya.nosy.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            // Do not wait for a playing process: silent starts must return immediately.
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapUUID.uuidString,
                kAudioSubTapDriftCompensationKey: true
            ]]
        ]
    }
    static var now: TimeInterval { AVAudioTime.seconds(forHostTime: mach_absolute_time()) }
}
