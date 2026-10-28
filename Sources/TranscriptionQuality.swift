import Darwin
import Foundation

enum TranscriptionQuality: String, CaseIterable, Identifiable, Sendable {
    case fast
    case detailed

    static let storageKey = "transcriptionQuality"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .fast: "Fast"
        case .detailed: "Detailed"
        }
    }
    var whisperArguments: [String] {
        switch self {
        case .fast: ["-bs", "1", "-bo", "1"]
        case .detailed: ["-bs", "5", "-bo", "5"]
        }
    }

    static func recommended(model: String, cpuBrand: String, performanceCores: Int?) -> Self {
        let model = model.lowercased()
        let chipWords = Set(cpuBrand.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        let isAir = model.hasPrefix("macbookair")
        let hasProClassChip = !chipWords.isDisjoint(with: ["pro", "max", "ultra"])
        let hasBaseAppleChip = (1...4).contains { chipWords.contains("m\($0)") } && !hasProClassChip

        if isAir || hasBaseAppleChip { return .fast }
        if hasProClassChip { return .detailed }
        if let performanceCores, performanceCores >= 6 { return .detailed }

        let isDesktop = model.hasPrefix("macmini") || model.hasPrefix("macstudio")
            || model.hasPrefix("macpro") || model.hasPrefix("imac")
        return isDesktop ? .detailed : .fast
    }

    @discardableResult
    static func loadOrSelect(defaults: UserDefaults = .standard, hardware: Hardware = .current) -> Self {
        if let saved = defaults.string(forKey: storageKey), let quality = Self(rawValue: saved) {
            return quality
        }
        let quality = recommended(model: hardware.model, cpuBrand: hardware.cpuBrand,
                                  performanceCores: hardware.performanceCores)
        if defaults.object(forKey: storageKey) == nil {
            defaults.set(quality.rawValue, forKey: storageKey)
        }
        return quality
    }

    struct Hardware: Sendable {
        let model: String
        let cpuBrand: String
        let performanceCores: Int?

        static var current: Hardware {
            Hardware(model: sysctlString("hw.model") ?? "",
                     cpuBrand: sysctlString("machdep.cpu.brand_string") ?? "",
                     performanceCores: sysctlInt("hw.perflevel0.physicalcpu"))
        }

        private static func sysctlString(_ name: String) -> String? {
            var size = 0
            guard name.withCString({ sysctlbyname($0, nil, &size, nil, 0) }) == 0, size > 1 else { return nil }
            var bytes = [CChar](repeating: 0, count: size)
            let status = name.withCString { key in
                bytes.withUnsafeMutableBufferPointer { buffer in
                    sysctlbyname(key, buffer.baseAddress, &size, nil, 0)
                }
            }
            guard status == 0 else { return nil }
            return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }

        private static func sysctlInt(_ name: String) -> Int? {
            var value: Int32 = 0
            var size = MemoryLayout<Int32>.size
            let status = name.withCString { sysctlbyname($0, &value, &size, nil, 0) }
            return status == 0 ? Int(value) : nil
        }
    }
}
