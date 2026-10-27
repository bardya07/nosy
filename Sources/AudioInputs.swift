import CoreAudio
import Foundation

enum AudioInputs {
    enum Transport: String, Sendable {
        case builtIn
        case wired
        case bluetooth
        case other

        static func classify(_ type: UInt32) -> Self {
            switch type {
            case kAudioDeviceTransportTypeBuiltIn: .builtIn
            case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: .bluetooth
            case kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeFireWire,
                 kAudioDeviceTransportTypePCI, kAudioDeviceTransportTypeThunderbolt,
                 kAudioDeviceTransportTypeAVB: .wired
            default: .other
            }
        }
    }

    struct Device: Identifiable, Hashable, Sendable {
        let id: String // CoreAudio device UID, stable across device-ID changes.
        let name: String
        let transport: Transport

        init(id: String, name: String, transport: Transport = .other) {
            self.id = id
            self.name = name
            self.transport = transport
        }
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

    static func deviceID(uid: String) -> AudioDeviceID? {
        deviceIDs().first { hasInput($0) && stringProperty(kAudioDevicePropertyDeviceUID, on: $0) == uid }
    }

    static func device(uid: String) -> Device? { list().first { $0.id == uid } }

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
        return Device(id: uid, name: name, transport: Transport.classify(transportType(on: id)))
    }

    private static func transportType(on id: AudioDeviceID) -> UInt32 {
        var property = address(kAudioDevicePropertyTransportType), value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &property, 0, nil, &size, &value) == noErr else { return 0 }
        return value
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

    // The device list and the default input, read together.
    struct Reading: Equatable, Sendable {
        let devices: [Device]
        let systemDefault: Device?
    }
    static func reading() -> Reading {
        Reading(devices: list(), systemDefault: systemDefault())
    }

    // Watches the device list and the default input. Changes arrive in bursts (a cable pulled, a dock
    // connected), so each burst is coalesced for 200 ms on a utility queue and read there. Nothing here
    // selects a device: the recorder observes routing independently while capturing.
    final class Watcher: @unchecked Sendable {
        // `active` and `pending` are confined to `queue`; `listeners` is touched only by start and invalidate on the main actor.
        private let queue = DispatchQueue(label: "com.bardya.nosy.audio-inputs", qos: .utility)
        private let deliver: @MainActor (Reading) -> Void
        @MainActor private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
        @MainActor private var observation = 0
        private var generation = 0 // Queue-confined delivery token.
        private var active = false
        private var pending: DispatchWorkItem?

        init(deliver: @escaping @MainActor (Reading) -> Void) {
            self.deliver = deliver
        }

        // Registers CoreAudio listeners for the device list and the default input. Nothing is read until a change or request.
        @MainActor func start() {
            guard listeners.isEmpty else { return }
            observation &+= 1
            let token = observation
            queue.async { self.active = true; self.generation = token }
            let system = AudioObjectID(kAudioObjectSystemObject)
            for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] {
                var address = AudioInputs.address(selector)
                // CoreAudio runs this block on `queue`.
                let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                    self?.schedule(after: 0.2)
                }
                if AudioObjectAddPropertyListenerBlock(system, &address, queue, listener) == noErr {
                    listeners.append((address, listener))
                }
            }
        }

        // Explicit refreshes (hovering or opening the microphone menu) join the same pending read.
        func request(after delay: TimeInterval = 0) {
            queue.async { [self] in schedule(after: delay) }
        }

        // Removes exactly the listeners that were added and drops any read that has not started.
        @MainActor func invalidate() {
            observation &+= 1
            queue.async {
                self.active = false
                self.pending?.cancel()
                self.pending = nil
            }
            let system = AudioObjectID(kAudioObjectSystemObject)
            for (address, listener) in listeners {
                var address = address
                _ = AudioObjectRemovePropertyListenerBlock(system, &address, queue, listener)
            }
            listeners = []
        }

        // Runs on `queue`. A request made while a read is pending shares that read.
        private func schedule(after delay: TimeInterval) {
            guard active, pending == nil else { return }
            let work = DispatchWorkItem { [weak self] in self?.readAndDeliver() }
            pending = work
            queue.asyncAfter(deadline: .now() + delay, execute: work)
        }

        // Runs on `queue`: reads the system, then hands the immutable result to the main actor.
        private func readAndDeliver() {
            pending = nil
            guard active else { return }
            let reading = AudioInputs.reading()
            let deliver = deliver
            let token = generation
            Task { @MainActor [weak self] in
                guard let self, self.observation == token else { return }
                deliver(reading)
            }
        }
    }
}
