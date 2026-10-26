import Foundation

struct RecordingLevelGuidance: Equatable {
    enum Band: Equatable { case quiet, good, loud }

    // The fixed-count entry point supports callers with a regular 10 Hz sample clock.
    static let samplesPerSecond = 10
    static let smoothingSeconds = 3
    static let sampleLimit = samplesPerSecond * smoothingSeconds
    static let recommendedRange = 55...75

    private(set) var samples: [Int] = []
    private var timestamps: [TimeInterval] = []
    private(set) var smoothedLevel = 20
    private(set) var band: Band = .quiet

    mutating func add(_ level: Int) -> Int {
        timestamps.removeAll(keepingCapacity: true)
        samples.append(level)
        if samples.count > Self.sampleLimit { samples.removeFirst(samples.count - Self.sampleLimit) }
        return updateLevel()
    }

    // Live delivery may be bursty. Retain the actual last three recorded seconds, independent of delivery rate.
    mutating func add(_ level: Int, at time: TimeInterval) -> Int {
        guard time.isFinite, time >= 0 else { return smoothedLevel }
        if timestamps.count != samples.count || timestamps.last.map({ time < $0 }) == true { reset() }
        if timestamps.last == time {
            samples[samples.count - 1] = level
        } else {
            timestamps.append(time)
            samples.append(level)
        }
        let expired = timestamps.prefix { $0 <= time - Double(Self.smoothingSeconds) }.count
        timestamps.removeFirst(expired)
        samples.removeFirst(expired)
        return updateLevel()
    }

    private mutating func updateLevel() -> Int {
        smoothedLevel = Int((Double(samples.reduce(0, +)) / Double(samples.count)).rounded())
        band = Self.nextBand(level: smoothedLevel, current: band)
        return smoothedLevel
    }

    mutating func reset() {
        samples.removeAll(keepingCapacity: true)
        timestamps.removeAll(keepingCapacity: true)
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
