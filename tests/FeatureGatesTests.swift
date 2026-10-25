import Foundation

@main
enum FeatureGatesTests {
    static func main() {
        let suite = "nosy-feature-gates-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        check(!AIFeatures.enabled(defaults), "AI features are off by default")
        defaults.set(true, forKey: AIFeatures.storageKey)
        check(AIFeatures.enabled(defaults), "AI features persist as on")
        defaults.set(false, forKey: AIFeatures.storageKey)
        check(!AIFeatures.enabled(defaults), "AI features persist as off")
        print("FEATURE GATE TESTS PASS")
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }
}
