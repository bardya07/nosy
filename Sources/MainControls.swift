import AppKit
import Foundation

// Pure rules behind the main window's controls, so tests can check them without a window.

// Start needs a session name. Asking for one turns the red line on; typing a name turns it off.
struct SessionNameGate: Equatable {
    static let message = "Name this session first"
    private(set) var required = false

    mutating func request() { required = true }

    mutating func sessionChanged(to name: String) {
        if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { required = false }
    }
}

// Which reading the live meter shows first. Tapping the readout switches between them, and the choice is saved.
enum LevelDisplay: String, CaseIterable, Sendable {
    static let storageKey = "levelDisplay"
    case estimate, technical

    static func stored(_ raw: String?) -> LevelDisplay { raw.flatMap(LevelDisplay.init(rawValue:)) ?? .estimate }
    var toggled: LevelDisplay { self == .estimate ? .technical : .estimate }
}

// Level readouts for the live input meter. Silence reads as minus infinity, never as a number.
enum InputLevel {
    static let silent = -160.0

    // The technical value: decibels below full scale, with a true minus sign, e.g. "−38 dBFS".
    static func technical(_ decibels: Double) -> String {
        guard decibels.isFinite else { return "\u{2212}\u{221E} dBFS" }
        let rounded = Int(decibels.rounded())
        if rounded <= -100 { return "\u{2212}\u{221E} dBFS" }
        if rounded >= 0 { return "0 dBFS" }
        // A true minus sign, not a hyphen, so the stat reads as a level in the window.
        return "\u{2212}\(-rounded) dBFS"
    }

    // An everyday estimate of how loud the room is. Digital levels (dBFS) are not sound levels, so this adds a
    // calibration offset. The offset is an assumption, not a measurement: 94 dB is the usual microphone reference
    // tone, and it lands typical Mac microphones at speaking distance near the middle of the scale.
    static let estimateOffset = 94.0
    static let estimateRange = 20...110

    // The estimated sound level in whole decibels. Silence and anything below the range read at the bottom.
    static func estimate(_ decibels: Double) -> Int {
        guard decibels.isFinite else { return estimateRange.lowerBound }
        let value = min(Double(estimateRange.upperBound), max(Double(estimateRange.lowerBound), (decibels + estimateOffset).rounded()))
        return Int(value)
    }

    static func estimateText(_ decibels: Double) -> String { "\u{2248} \(estimate(decibels)) dB" }

    // Quiet and Loud bands for lecture speech. Quiet is hard to hear across a room; Loud is close to clipping.
    enum Band: Equatable, CaseIterable {
        case quiet, good, loud
        var label: String {
            switch self {
            case .quiet: "Quiet"
            case .good: "Good"
            case .loud: "Loud"
            }
        }
    }
    static func band(_ decibels: Double) -> Band {
        let level = estimate(decibels)
        if level < 50 { return .quiet }
        if level < 75 { return .good }
        return .loud
    }

    // The primary readout for the chosen display.
    static func primary(_ decibels: Double, display: LevelDisplay) -> String {
        switch display {
        case .estimate: estimateText(decibels)
        case .technical: technical(decibels)
        }
    }

    // Bar length for the meter: -60 dB is empty and 0 dB is full.
    static func fraction(_ decibels: Double) -> Double {
        guard decibels.isFinite else { return 0 }
        return min(1, max(0, (decibels + 60) / 60))
    }
}

// How often Nosy reminds you while recording ("Still recording. Forgot to stop?"). Zero means never.
// Each reminder repeats at the same interval, counted from the last one.
enum ReminderInterval {
    static let storageKey = "reminderIntervalMinutes"
    // Older builds stored whole hours before the first reminder, with 0 meaning never.
    static let legacyHoursKey = "remindAfterHours"
    static let defaultMinutes = 60
    static let never = 0
    static let presets = [30, 60, 120, 180]
    static let customRange = 5...1440
    static let customStep = 5

    // Copies an older hours setting into the minutes setting, once. A saved minutes value always wins.
    static func migrate(_ defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: storageKey) == nil, let hours = defaults.object(forKey: legacyHoursKey) as? Int else { return }
        defaults.set(hours <= 0 ? never : hours * 60, forKey: storageKey)
    }

    static func stored(_ defaults: UserDefaults = .standard) -> Int {
        normalized(defaults.object(forKey: storageKey) as? Int ?? defaultMinutes)
    }

    static func save(_ minutes: Int, _ defaults: UserDefaults = .standard) {
        defaults.set(normalized(minutes), forKey: storageKey)
    }

    // Keeps a saved value inside what the setting offers: never, or 5 minutes to 24 hours.
    static func normalized(_ minutes: Int) -> Int {
        minutes <= 0 ? never : min(max(minutes, customRange.lowerBound), customRange.upperBound)
    }

    // Plain words for the setting: "Every hour", "Every 45 minutes", "Every 1 hour 30 minutes", "Never".
    static func label(_ minutes: Int) -> String {
        switch minutes {
        case never: return "Never"
        case 30: return "Every 30 minutes"
        case 60: return "Every hour"
        case 120: return "Every 2 hours"
        case 180: return "Every 3 hours"
        default: return "Every \(duration(minutes))"
        }
    }

    static func duration(_ minutes: Int) -> String {
        let hours = minutes / 60
        let rest = minutes % 60
        var parts: [String] = []
        if hours > 0 { parts.append(hours == 1 ? "1 hour" : "\(hours) hours") }
        if rest > 0 { parts.append(rest == 1 ? "1 minute" : "\(rest) minutes") }
        return parts.joined(separator: " ")
    }
}

// Deleting a folder: the one path both the main window and the Transcripts window use. Only a folder
// directly inside the transcript library can move, the move is the system Trash so it stays
// recoverable, and the owner confirms first.
enum LectureFolderTrash {
    typealias Mover = (URL) throws -> Void

    // Settings → General "Ask before deleting folders" and the alert's "Don't ask again" share this key.
    static let askKey = "askBeforeDeletingFolders"
    static func asks(_ defaults: UserDefaults = .standard) -> Bool { defaults.object(forKey: askKey) as? Bool ?? true }

    static func systemTrash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    static func move(_ lecture: String, paths: AppPaths, mover: Mover = LectureFolderTrash.systemTrash) throws {
        try paths.validateLectureFolder(lecture)
        let folder = paths.lectureFolder(lecture)
        // Compare normalized paths only; the mover gets the folder exactly as the library spells it.
        let root = paths.transcripts.resolvingSymlinksInPath().standardizedFileURL
        let parent = folder.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        // A link that points outside the library fails the containment check, so its target is never moved.
        guard parent == root, Core.isContained(folder, in: paths.transcripts),
              FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw LectureError.message("That folder is no longer in your transcript library.")
        }
        try mover(folder)
    }

    // The one confirmation for deleting a folder. Cancel is the default so a stray Return never moves it.
    // With "Don't ask again" on, the folder moves without asking. The choice is saved only when the owner confirms.
    @MainActor static func confirm(_ lecture: String, defaults: UserDefaults = .standard) -> Bool {
        guard asks(defaults) else { return true }
        let confirmation = makeConfirmation(lecture)
        guard confirmation.alert.runModal() == .alertFirstButtonReturn else { return false }
        if confirmation.dontAsk.state == .on { defaults.set(false, forKey: askKey) }
        return true
    }

    @MainActor static func makeConfirmation(_ lecture: String) -> (alert: NSAlert, dontAsk: NSButton) {
        let alert = NSAlert()
        alert.messageText = "Move \"\(lecture)\" and its transcripts to the Trash?"
        let trash = alert.addButton(withTitle: "Move to Trash")
        trash.hasDestructiveAction = true
        trash.keyEquivalent = ""
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\r"
        let dontAsk = NSButton(checkboxWithTitle: "Don't ask again", target: nil, action: nil)
        dontAsk.sizeToFit()
        alert.accessoryView = dontAsk
        return (alert, dontAsk)
    }
}
