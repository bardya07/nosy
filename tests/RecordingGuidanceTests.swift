import Foundation

@main
enum RecordingGuidanceTests {
    static func main() {
        var guidance = RecordingLevelGuidance()
        for _ in 0..<30 { _ = guidance.add(65) }
        check(guidance.smoothedLevel == 65 && guidance.band == .good, "three seconds of a good level reads good")
        _ = guidance.add(78)
        check(guidance.band == .good, "one loud sample does not change the smoothed guidance")
        for _ in 0..<30 { _ = guidance.add(100) }
        check(guidance.band == .loud, "a sustained high level reads loud")
        for _ in 0..<30 { _ = guidance.add(70) }
        check(guidance.band == .good, "a sustained level in range returns to good")
        for _ in 0..<30 { _ = guidance.add(30) }
        check(guidance.band == .quiet, "a sustained low level reads quiet")
        check(RecordingLevelGuidance.nextBand(level: 56, current: .quiet) == .quiet, "quiet guidance has a lower transition threshold")
        check(RecordingLevelGuidance.nextBand(level: 57, current: .quiet) == .good, "quiet guidance transitions inside the recommended range")
        check(RecordingLevelGuidance.nextBand(level: 54, current: .good) == .good, "good guidance has hysteresis at the quiet edge")
        check(RecordingLevelGuidance.nextBand(level: 52, current: .good) == .quiet, "good guidance exits below the quiet edge")
        check(RecordingLevelGuidance.recommendedRange == 55...75, "the displayed recommendation matches the meter band")
        print("RECORDING GUIDANCE TESTS PASS")
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }
}
