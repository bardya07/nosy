import Foundation

@main
enum AIFeatureSchedulingTests {
    @MainActor
    static func main() {
        let suite = "nosy-ai-scheduling-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(SummaryProvider.claudeCode.rawValue, forKey: SummarySettings.providerKey)
        defaults.set(true, forKey: SummarySettings.automaticKey)

        let center = SummaryCenter()
        center.defaults = defaults
        let transcript = URL(fileURLWithPath: "/tmp/ai-features-off.md")
        center.transcriptSaved(transcript)
        center.summarize(transcript)
        center.findMoments(transcript, paths: AppPaths())

        check(center.status(for: transcript) == nil, "AI off blocks automatic and requested summaries")
        check(center.momentStatus(for: transcript) == nil, "AI off blocks requested key moments")
        check(!center.hasPendingWork, "AI off queues no model work")
        print("AI FEATURE SCHEDULING TESTS PASS")
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }
}
