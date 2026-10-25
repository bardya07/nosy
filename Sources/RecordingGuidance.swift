import Foundation

struct RecordingLevelGuidance: Equatable {
    enum Band: Equatable { case quiet, good, loud }

    // Ten samples a second keeps the level close to the requested three second guidance window.
    static let samplesPerSecond = 10
    static let smoothingSeconds = 3
    static let sampleLimit = samplesPerSecond * smoothingSeconds
    static let recommendedRange = 55...75

    private(set) var samples: [Int] = []
    private(set) var smoothedLevel = 20
    private(set) var band: Band = .quiet

    mutating func add(_ level: Int) -> Int {
        samples.append(level)
        if samples.count > Self.sampleLimit { samples.removeFirst(samples.count - Self.sampleLimit) }
        smoothedLevel = Int((Double(samples.reduce(0, +)) / Double(samples.count)).rounded())
        band = Self.nextBand(level: smoothedLevel, current: band)
        return smoothedLevel
    }

    mutating func reset() {
        samples.removeAll(keepingCapacity: true)
        smoothedLevel = 20
        band = .quiet
    }

    static func nextBand(level: Int, current: Band) -> Band {
        switch current {
        case .quiet:
            if level >= 77 { return .loud }
            if level >= 57 { return .good }
            return .quiet
        case .good:
            if level < 53 { return .quiet }
            if level > 77 { return .loud }
            return .good
        case .loud:
            if level < 53 { return .quiet }
            if level <= 73 { return .good }
            return .loud
        }
    }
}
