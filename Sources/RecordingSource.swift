import Foundation

enum RecordingSource: String, CaseIterable, Sendable {
    case mic, macAudio, both

    var title: String {
        switch self {
        case .mic: "Mic"
        case .macAudio: "Mac audio"
        case .both: "Both"
        }
    }
    var usesMic: Bool { self != .macAudio }
    var usesMacAudio: Bool { self != .mic }
    static var macAudioAvailable: Bool {
        if #available(macOS 14.4, *) { return true }
        return false
    }
    static var available: [Self] { macAudioAvailable ? allCases : [.mic] }
    static func restored(_ value: String?) -> Self {
        let source = value.flatMap(Self.init(rawValue:)) ?? .mic
        return available.contains(source) ? source : .mic
    }
    static func canChange(recording: Bool, paused: Bool, transitioning: Bool) -> Bool {
        !transitioning && (!recording || paused)
    }
    func inputName(mic: String) -> String {
        switch self {
        case .mic: mic
        case .macAudio: "Mac audio"
        case .both: "\(mic) + Mac audio"
        }
    }
}
