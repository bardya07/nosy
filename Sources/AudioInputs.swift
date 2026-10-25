import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
#if canImport(NosyAudioBridge)
import NosyAudioBridge
#endif

enum AudioInputs {
    struct Device: Identifiable, Hashable, Sendable {
        let id: String // CoreAudio device UID, stable across device-ID changes.
        let name: String
    }

    static func list() -> [Device] {
        let defaultID = defaultDeviceID()
        return deviceIDs().compactMap { id -> (id: AudioDeviceID, device: Device)? in
            guard hasInput(id), let device = description(id), isUserVisible(device) else { return nil }
            return (id, device)
        }.sorted { lhs, rhs in
            if (lhs.id == defaultID) != (rhs.id == defaultID) { return lhs.id == defaultID }
            let order = lhs.device.name.localizedStandardCompare(rhs.device.name)
            return order == .orderedSame ? lhs.device.id < rhs.device.id : order == .orderedAscending
        }.map(\.device)
    }

    static func isUserVisible(_ device: Device) -> Bool {
        // CoreAudio's private default-device proxy is not a selectable microphone.
        // Do not hide named aggregates intentionally created in Audio MIDI Setup.
        !device.name.hasPrefix("CADefaultDeviceAggregate-") && !device.id.hasPrefix("CADefaultDeviceAggregate-")
    }

    static func systemDefault() -> Device? {
        guard let id = defaultDeviceID(), hasInput(id) else { return nil }
        return description(id)
    }

    static func current(on engine: AVAudioEngine) -> Device? {
        guard let input = try? inputNode(on: engine), let unit = input.audioUnit else { return nil }
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global,
                                   0, &id, &size) == noErr else { return nil }
        return description(id)
    }

    static func deviceID(uid: String) -> AudioDeviceID? {
        deviceIDs().first { hasInput($0) && stringProperty(kAudioDevicePropertyDeviceUID, on: $0) == uid }
    }

    // Call on the engine's control queue while stopped, before reading its input format.
    // nil preserves AVAudioEngine's automatic system-default routing.
    // A missing UID restores the default even if this engine previously used that device.
    static func apply(uid: String?, to engine: AVAudioEngine) throws -> Bool {
        guard let uid else { return true }
        if let id = deviceID(uid: uid) {
            do {
                try setDevice(id, on: engine)
                return true
            } catch {
                // A device can disappear between enumeration and AudioUnitSetProperty.
                guard deviceID(uid: uid) == nil else { throw error }
            }
        }
        if let id = defaultDeviceID() { try setDevice(id, on: engine) }
        return false
    }

    private static func setDevice(_ id: AudioDeviceID, on engine: AVAudioEngine) throws {
        guard let unit = try inputNode(on: engine).audioUnit else {
            throw LectureError.message("The microphone audio unit is unavailable.")
        }
        var current = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        // Avoid generating another configuration-change notification on each restart.
        if AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global,
                                0, &current, &size) == noErr, current == id { return }
        var device = id
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global,
                                         0, &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Could not select the microphone (CoreAudio error \(status))."])
        }
    }
    private static func inputNode(on engine: AVAudioEngine) throws -> AVAudioInputNode {
        #if canImport(NosyAudioBridge)
        var error: NSError?
        if let input = NosyAudioInput(engine, &error) { return input }
        throw error ?? LectureError.message("The microphone is unavailable.")
        #else
        throw LectureError.message("Nosy's audio support is missing. Reinstall Nosy, then try again.")
        #endif
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func deviceIDs() -> [AudioDeviceID] {
        var property = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        let stride = MemoryLayout<AudioDeviceID>.stride
        guard AudioObjectGetPropertyDataSize(system, &property, 0, nil, &size) == noErr,
              size > 0, Int(size) % stride == 0 else { return [] }
        var devices = [AudioDeviceID](repeating: kAudioObjectUnknown, count: Int(size) / stride)
        let capacity = size
        let status = devices.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(system, &property, 0, nil, &size, $0.baseAddress!)
        }
        guard status == noErr, size <= capacity, Int(size) % stride == 0 else { return [] }
        return Array(devices.prefix(Int(size) / stride))
    }

    private static func defaultDeviceID() -> AudioDeviceID? {
        var property = address(kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &id) == noErr,
              size == MemoryLayout<AudioDeviceID>.size, id != kAudioObjectUnknown else { return nil }
        return id
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var property = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &property, 0, nil, &size) == noErr,
              size >= MemoryLayout<AudioBufferList>.size else { return false }
        let capacity = Int(size)
        let storage = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(id, &property, 0, nil, &size, storage) == noErr,
              size <= capacity, size >= MemoryLayout<AudioBufferList>.size else { return false }
        let list = storage.assumingMemoryBound(to: AudioBufferList.self)
        let headerSize = MemoryLayout<AudioBufferList>.offset(of: \.mBuffers)!
        guard Int(list.pointee.mNumberBuffers) <= (Int(size) - headerSize) / MemoryLayout<AudioBuffer>.stride else { return false }
        return UnsafeMutableAudioBufferListPointer(list).contains { $0.mNumberChannels > 0 }
    }

    private static func description(_ id: AudioDeviceID) -> Device? {
        guard let uid = stringProperty(kAudioDevicePropertyDeviceUID, on: id),
              let name = stringProperty(kAudioObjectPropertyName, on: id) else { return nil }
        return Device(id: uid, name: name)
    }

    private static func stringProperty(_ selector: AudioObjectPropertySelector, on id: AudioDeviceID) -> String? {
        var property = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &property, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        // Both the name and UID properties return CF objects owned by the caller.
        return value.takeRetainedValue() as String
    }
}
