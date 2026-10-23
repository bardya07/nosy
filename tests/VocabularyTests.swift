import Foundation

@main enum VocabularyTests {
    static func main() throws {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            count += 1
            guard value() else { fatalError("FAIL: \(message)") }
        }
        let catalog = SubjectCatalog(packs: [
            "stem-core": ["gray", "alpha"],
            "immune": ["thymocyte", "Notch ligand", "pre-T-cell receptor", "T-cell receptor", "CD4", "IT", "SO", "shared marker"],
            "other": ["shared marker", "Notch ligand"]
        ], subjectPacks: ["biology": ["immune", "other", "stem-core"]])
        check(SubjectCatalog.guess("MBB326") == ["biology"], "compact course prefix")
        check(SubjectCatalog.guess("Week 3 discussion").isEmpty, "no substring CS guess")
        check(SubjectSettings(subject: "chemistry").resolved(course: "MBB 326") == ["chemistry"], "manual wins")
        check(SubjectSettings(subject: "off").resolved(course: "MBB326").isEmpty, "custom only")
        let route = catalog.route(text: "thymocytes, Notch ligand, pre T cell receptor, CD4. it so gray alpha.", eligible: ["immune", "other", "stem-core"])
        check(route.selected == ["immune"], "audited route with distinct markers")
        check(route.distinct["immune"] == 4, "longest phrase owns overlap")
        check(route.scores["immune"] == 3.5, "shared term fractional vote")
        check(catalog.route(text: String(repeating: "it SO cd4 gray thymocyte ", count: 50), eligible: ["immune", "other"]).selected.isEmpty, "short, case and repetition traps abstain")
        let index = VocabularyIndex(terms: ["conformation", "thymocyte", "CD4", "CD8"])
        let hits = index.retrieve("The confirmation of this protein changes.")
        check(hits.contains { $0.source == "confirmation" && $0.term == "conformation" }, "spelling retrieves technical near miss")
        check(!index.retrieve("CD4 and CD8 on thymocyte").contains { ["CD4", "CD8"].contains($0.term) }, "short acronyms excluded")
        check(!index.retrieve("the thymocyte").contains { $0.term == "thymocyte" }, "never swallow correctly recognized word with its article")
        let candidate = VocabularyCandidate(term: "conformation", source: "confirmation", location: 4, length: 12, spelling: 0.92, phonetic: 0.9, margin: 0.2)
        let original = "The confirmation changes here."
        let retry = "The conformation changes here."
        let accepted = VocabularyAcceptance.edits(original: original, retry: retry, candidates: [candidate], confidence: { _ in 0.4 })
        check(accepted.count == 1 && VocabularyAcceptance.applying(accepted, to: original) == retry, "bounded term substitution accepted")
        check(VocabularyAcceptance.edits(original: original, retry: "The conformation never changes here.", candidates: [candidate], confidence: { _ in 0.4 }).isEmpty, "negation and unrelated edit rejected")
        check(VocabularyAcceptance.edits(original: original, retry: retry, candidates: [candidate], confidence: { _ in 0.95 }).isEmpty, "confident original preserved")
        check(VocabularyAcceptance.edits(original: original, retry: retry, candidates: [candidate], confidence: { _ in nil }).isEmpty, "missing confidence abstains")
        check(VocabularyAcceptance.edits(original: original, retry: nil, candidates: [candidate], confidence: { _ in 0.2 }, substitute: true).isEmpty, "phonetic threshold for leftovers stricter")
        let pairText = "The confirmation changes the confirmation here."
        let first = VocabularyCandidate(term: "conformation", source: "confirmation", location: 4, length: 12, spelling: 0.92, phonetic: 0.9, margin: 0.2)
        let second = VocabularyCandidate(term: "conformation", source: "confirmation", location: 29, length: 12, spelling: 0.92, phonetic: 0.9, margin: 0.2)
        check(VocabularyAcceptance.edits(original: pairText, retry: "The conformation changes the conformation here.", candidates: [first,second], confidence: { _ in 0.4 }).count == 2, "joint alignment accepts two supported terms")
        check(VocabularyAcceptance.edits(original: original, retry: retry, candidates: [candidate], confidence: { _ in 0.95 }, requireConfidence: false).count == 1, "independent experiment can isolate confidence gating")
        check(VocabularyAcceptance.loops("this is a repeated sentence this is a repeated sentence this is a repeated sentence"), "loop rejection")
        check(!VocabularyAcceptance.loops(original), "normal text retained")
        check(VocabularySimilarity.risky("Ames") && VocabularySimilarity.risky("CD4") && VocabularySimilarity.risky("MBB 331"), "short and digit identity abstention")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let settings = SubjectSettings(subject: "biology", additionalSubject: "chemistry")
        try settings.save(folder: folder)
        let loaded = try SubjectSettings.load(folder: folder)
        check(loaded == settings, "per-course settings round trip")
        try Data("{\"schemaVersion\":99,\"subject\":\"biology\",\"additionalSubject\":\"\"}".utf8).write(to: folder.appendingPathComponent("vocabulary.json"))
        do { _ = try SubjectSettings.load(folder: folder); fatalError("accepted unsupported settings") } catch { count += 1 }
        let bytes = Set((UInt8(0)...127).map { Data([$0]) })
        check(Vocabulary.prompt(["user first", "(2,4-dinitrophenyl)hydrazine"], vocabulary: bytes)?.text == "user first, (2,4-dinitrophenyl)hydrazine", "canonical internal commas stay intact, user first")
        print("VOCABULARY PASS: \(count) assertions")
    }
}
