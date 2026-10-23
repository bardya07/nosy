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

        let markedSource = "# 🧬 Course\n\n> [12:40] Exam hint 🧬\n\nCorrect this spelling."
        let markedBlocks = TranscriptBlock.parse(markedSource)
        if case .marker(let timestamp, let label) = markedBlocks[1].content {
            check(timestamp == "12:40" && label == "Exam hint 🧬", "reader renders timestamped marker labels")
        } else { fatalError("reader lost marker") }
        check(markedBlocks[1].sourceRange(NSRange(location: 0, length: 4)) == nil, "markers cannot become vocabulary corrections")
        let afterMarker = markedBlocks[2].sourceRange(NSRange(location: 13, length: 8))!
        check((markedSource as NSString).substring(with: afterMarker) == "spelling", "corrections after markers retain source offsets")

        let catalog = SubjectCatalog(packs: [
            "stem-core": ["gray", "alpha"],
            "immune": ["thymocyte", "Notch ligand", "pre-T-cell receptor", "T-cell receptor", "CD4", "IT", "SO", "shared marker"],
            "other": ["shared marker", "Notch ligand"]
        ], subjectPacks: ["biology": ["immune", "other", "stem-core"]])
        check(SubjectCatalog.guess("MBB322") == ["biology"], "MBB folder name guesses Biology")
        check(SubjectCatalog.guess("Biochemistry") == ["biology"], "Biochemistry aliases into Biology")
        check(SubjectCatalog.guess("CHEM 233") == ["chemistry"], "course code guesses Chemistry")
        check(SubjectCatalog.guess("CPSC 110") == ["computer-science"], "course code guesses Computer Science")
        check(SubjectCatalog.guess("Team sync") == ["meetings-work"], "meeting keywords guess Meetings & Work")
        check(SubjectCatalog.guess("Random") == ["general"], "unknown folder name guesses General")
        for (name, expected) in [("PHYS 101", "physics"), ("STAT 200", "math-statistics"),
                                 ("HSCI 210", "health-medicine"), ("PSYC 100", "psychology"),
                                 ("Business & Economics", "meetings-work"), ("Engineering", "general")] {
            check(SubjectCatalog.guess(name) == [expected], "Auto guesses " + name + " correctly")
        }
        check(SubjectCatalog.subjects.map(\.name) == ["Biology", "Chemistry", "Physics", "Computer Science", "Math & Statistics", "Health & Medicine", "Psychology", "Meetings & Work"],
              "subject catalog has the requested eight options")
        for keyword in ["standup", "1:1", "client", "interview", "review", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"] {
            check(SubjectCatalog.guess(keyword) == ["meetings-work"], "meeting keyword " + keyword + " guesses Meetings & Work")
        }
        check(SubjectCatalog.guess("Computer Science 110") == ["computer-science"], "full subject title")
        check(SubjectCatalog.guess("Week 3 discussion") == ["general"], "unknown names do not get a substring CS guess")
        check(SubjectSettings(subject: "chemistry").resolved(course: "MBB 326") == ["chemistry"], "manual wins")
        check(SubjectSettings(subject: "general").resolved(course: "MBB322").isEmpty, "General disables subject packs")
        check(SubjectSettings(subject: "auto").resolved(course: "Random") == ["general"], "Auto resolves unknown folders to General")
        let route = catalog.route(text: "thymocytes, Notch ligand, pre T cell receptor, CD4. it so gray alpha.", eligible: ["immune", "other", "stem-core"])
        check(route.selected == ["immune"], "audited route with distinct markers")
        check(route.distinct["immune"] == 4, "longest phrase owns overlap")
        check(route.scores["immune"] == 3.5, "shared term fractional vote")
        check(catalog.route(text: String(repeating: "it SO cd4 gray thymocyte ", count: 50), eligible: ["immune", "other"]).selected.isEmpty, "short, case and repetition traps abstain")
        let index = VocabularyIndex(terms: ["heterochromatin", "CD4", "CD8"])
        let sanitizedOneToOne = try Core.sanitize("Alex 1:1")
        check(sanitizedOneToOne == "Alex 1-1" && SubjectCatalog.guess(sanitizedOneToOne) == ["meetings-work"],
              "Auto recognizes a 1:1 folder after app name sanitization")
        let splitTermHits = VocabularyIndex(terms: ["immune response"]).retrieve("The imune\nresponse is here.")
        check(!splitTermHits.contains(where: { $0.source.contains("\n") }),
              "vocabulary retrieval cannot match a phrase across transcript segments")
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
        check(remembered == "thymocyte\nheterochromatin\n", "corrections prepend once in captured folder")
        let initial = try SubjectSettings.load(folder: folder)
        check(initial.subject == "auto" && initial.isEnabled, "folders without a choice default to Auto and enable subject vocabulary")
        UserDefaults.standard.setVolatileDomain(["smarterVocabulary": false], forName: UserDefaults.argumentDomain)
        check((try? SubjectSettings.load(folder: folder))?.isEnabled == true, "obsolete global off cannot override folder Auto")
        let settings = SubjectSettings(subject: "biology", additionalSubject: "chemistry")
        try settings.save(folder: folder)
        let loaded = try SubjectSettings.load(folder: folder)
        check(loaded == settings, "explicit legacy subject and secondary choice survive round trip")
        check(loaded.isEnabled, "explicit subject enables vocabulary")
        try SubjectSettings(subject: "general").save(folder: folder)
        let disabledSettings = try SubjectSettings.load(folder: folder)
        check(!disabledSettings.isEnabled && disabledSettings.resolved(course: "Biology").isEmpty, "explicit General remains disabled")

        func legacySettings(_ name: String, subject: String, additionalSubject: String = "") throws -> URL {
            let directory = folder.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let json = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "subject": subject, "additionalSubject": additionalSubject])
            try json.write(to: directory.appendingPathComponent("vocabulary.json"))
            return directory
        }
        let oldBiochemistry = try SubjectSettings.load(folder: legacySettings("legacy-biochemistry", subject: "biochemistry"))
        check(oldBiochemistry.subject == "biology", "Biochemistry setting migrates to Biology")
        let oldBusiness = try SubjectSettings.load(folder: legacySettings("legacy-business", subject: "business-economics", additionalSubject: "biochemistry"))
        check(oldBusiness.subject == "meetings-work" && oldBusiness.additionalSubject == "biology", "Business & Economics and Biochemistry settings migrate to Meetings & Work and Biology")
        let oldNoneFolder = try legacySettings("legacy-none", subject: "off")
        let oldNone = try SubjectSettings.load(folder: oldNoneFolder)
        check(oldNone.subject == "general" && !oldNone.isEnabled, "old None setting migrates to General")
        let rewritten = try JSONSerialization.jsonObject(with: Data(contentsOf: oldNoneFolder.appendingPathComponent("vocabulary.json"))) as! [String: Any]
        check(rewritten["subject"] as? String == "general", "migrated folder setting is saved in canonical form")
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
        let mappedPacks = Set(resources.subjectPacks.values.flatMap { $0 })
        check(resources.subjectPacks.count == 8 && resources.packs.count == 49 && mappedPacks == Set(resources.packs.keys),
              "all 49 bundled vocabulary packs are mapped to the eight subject groups")
        print("VOCABULARY PASS: \(count) assertions")
    }
}
