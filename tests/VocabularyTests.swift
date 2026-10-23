import Foundation

@main enum VocabularyTests {
    static func main() throws {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            count += 1
            guard value() else { fatalError("FAIL: \(message)") }
        }
        let markdown = "# 🧬 Course\n\n- Date: today\n- Length: 1 min\n\n## Transcript\n\nFirst spelling.\n\nRepeated 🧬 spelling\nwith another spelling."
        let blocks = TranscriptBlock.parse(markdown)
        check(blocks.count == 5, "reader retains title, metadata, heading and paragraphs")
        let last = blocks.last!
        guard case .paragraph(let paragraph) = last.content else { fatalError("missing reader paragraph") }
        let selected = (paragraph as NSString).range(of: "spelling", options: .backwards)
        let source = last.sourceRange(selected)!
        check((markdown as NSString).substring(with: source) == "spelling", "correction maps Unicode paragraph selection to source")
        check(source == (markdown as NSString).range(of: "spelling", options: .backwards), "repeated spelling corrects only the selected occurrence")
        check(last.sourceRange(NSRange(location: paragraph.utf16.count, length: 1)) == nil, "stale paragraph range rejected")
        check(blocks[0].sourceRange(NSRange(location: 0, length: 1)) == nil, "reader metadata cannot become a paragraph correction")

        let catalog = SubjectCatalog(packs: [
            "stem-core": ["gray", "alpha"],
            "immune": ["thymocyte", "Notch ligand", "pre-T-cell receptor", "T-cell receptor", "CD4", "IT", "SO", "shared marker"],
            "other": ["shared marker", "Notch ligand"]
        ], subjectPacks: ["biology": ["immune", "other", "stem-core"]])
        check(SubjectCatalog.guess("MBB326") == ["biology"], "compact course prefix")
        check(SubjectCatalog.guess("Computer Science 110") == ["computer-science"], "full subject title")
        check(SubjectCatalog.guess("Week 3 discussion").isEmpty, "no substring CS guess")
        check(SubjectSettings(subject: "chemistry").resolved(course: "MBB 326") == ["chemistry"], "manual wins")
        check(SubjectSettings(subject: "off").resolved(course: "MBB326").isEmpty, "custom only")
        let route = catalog.route(text: "thymocytes, Notch ligand, pre T cell receptor, CD4. it so gray alpha.", eligible: ["immune", "other", "stem-core"])
        check(route.selected == ["immune"], "audited route with distinct markers")
        check(route.distinct["immune"] == 4, "longest phrase owns overlap")
        check(route.scores["immune"] == 3.5, "shared term fractional vote")
        check(catalog.route(text: String(repeating: "it SO cd4 gray thymocyte ", count: 50), eligible: ["immune", "other"]).selected.isEmpty, "short, case and repetition traps abstain")
        let index = VocabularyIndex(terms: ["heterochromatin", "CD4", "CD8"])
        let original = "The heterochromatone is here."
        let hits = index.retrieve(original)
        let accepted = VocabularyAcceptance.edits(original: original, candidates: hits, confidence: { _ in 0.4 })
        check(accepted.count == 1 && VocabularyAcceptance.applying(accepted, to: original) == "The heterochromatin is here.", "accept exact phonetic and close spelling; retain all context")
        check(VocabularyAcceptance.edits(original: original, candidates: hits, confidence: { _ in 0.95 }).isEmpty, "confident original preserved")
        check(VocabularyAcceptance.edits(original: original, candidates: hits, confidence: { _ in nil }).isEmpty, "missing confidence abstains")
        check(index.retrieve(original).map(\.term) == hits.map(\.term), "cached search is deterministic")
        check(!index.retrieve("CD4 and CD8").contains { ["CD4", "CD8"].contains($0.term) }, "short acronyms excluded")
        check(VocabularyIndex(terms: ["thymocyte"]).retrieve("the thymocyte").isEmpty, "never swallow recognized word with article")
        let stale = VocabularyCandidate(term: "heterochromatin", source: "wrong", location: 0, length: 5, spelling: 1, phonetic: 1, margin: 1)
        check(VocabularyAcceptance.edits(original: original, candidates: [stale], confidence: { _ in 0.1 }).isEmpty, "stale source range rejected")
        let ambiguous = VocabularyCandidate(term: "heterochromatin", source: "heterochromatone", location: 4, length: 16, spelling: 0.9, phonetic: 1, margin: 0.01)
        check(VocabularyAcceptance.edits(original: original, candidates: [ambiguous], confidence: { _ in 0.1 }).isEmpty, "ambiguous candidate rejected")
        check(VocabularyAcceptance.loops("this is a repeated sentence this is a repeated sentence this is a repeated sentence"), "loop rejection")
        check(!VocabularyAcceptance.loops(original), "normal text retained")
        check(VocabularySimilarity.risky("Ames") && VocabularySimilarity.risky("CD4") && VocabularySimilarity.risky("MBB 331") && VocabularySimilarity.risky("T-cell receptor"), "short, letter and digit identity abstention")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Vocabulary.remember("heterochromatin", folder: folder)
        try Vocabulary.remember("thymocyte", folder: folder)
        try Vocabulary.remember("thymocyte", folder: folder)
        let remembered = try String(contentsOf: folder.appendingPathComponent("vocab.txt"), encoding: .utf8)
        check(remembered == "thymocyte\nheterochromatin\n", "corrections prepend once in captured course folder")
        let settings = SubjectSettings(subject: "biology", additionalSubject: "chemistry")
        try settings.save(folder: folder)
        let loaded = try SubjectSettings.load(folder: folder)
        check(loaded == settings, "per-course settings round trip")
        try Data("{\"schemaVersion\":99,\"subject\":\"biology\",\"additionalSubject\":\"\"}".utf8).write(to: folder.appendingPathComponent("vocabulary.json"))
        do { _ = try SubjectSettings.load(folder: folder); fatalError("accepted unsupported settings") } catch { count += 1 }
        let bytes = Set((UInt8(0)...127).map { Data([$0]) })
        check(Vocabulary.prompt(["user first", "(2,4-dinitrophenyl)hydrazine"], vocabulary: bytes)?.text == "user first, (2,4-dinitrophenyl)hydrazine", "canonical internal commas stay intact, user first")
        let fixture: [String: Any] = ["transcription": [["text": " " + original, "offsets": ["from": 0, "to": 2000], "tokens": [["id": 10, "text": " " + original, "p": 0.4]]]]]
        let data = try JSONSerialization.data(withJSONObject: fixture)
        let small = SubjectCatalog(packs: ["words": ["heterochromatin"]], subjectPacks: ["biology": ["words"]])
        let refined = try VocabularyRefinement.refine(original: original + "\n", data: data, catalog: small, subjects: ["biology"], userTerms: [])
        check(refined.edits.count == 1, "JSON token confidence gates real refinement path")
        let mismatched = try VocabularyRefinement.refine(original: "different output\n", data: data, catalog: small, subjects: ["biology"], userTerms: [])
        check(mismatched.text == "different output\n" && mismatched.edits.isEmpty, "JSON/text mismatch preserves baseline exactly")
        let disabled = try VocabularyRefinement.refine(original: original + "\n", data: data, catalog: small, subjects: ["biology"], userTerms: [], substitute: false)
        check(disabled.edits.isEmpty, "internal ablation switch")
        let resources = SubjectCatalog(directory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/Vocabulary"))
        check(resources.subjectPacks.count == 10 && resources.packs.count == 49, "all exported subjects and packs load")
        print("VOCABULARY PASS: \(count) assertions")
    }
}
