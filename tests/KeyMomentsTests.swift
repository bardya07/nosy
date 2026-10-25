import Foundation

// Find key moments: prompt and schema building, reply validation, label rules, spacing and the cap,
// approximate times for old transcripts, chunk overlap, the engine with scripted replies, placement in
// the reader, and sidecar persistence and removal. NOSY_KEY_MOMENTS_TRANSCRIPT runs the real local model
// once on one transcript and prints what it found; nothing is written anywhere.
@main
enum KeyMomentsTests {
    static func main() async {
        do {
            try await run()
            print("KEY MOMENTS TESTS PASS: schema and prompts, validation, selection, approximate times, chunking, engine, placement, persistence, removal")
            if let transcript = ProcessInfo.processInfo.environment["NOSY_KEY_MOMENTS_TRANSCRIPT"] {
                try await realRun(transcript)
            }
        } catch {
            FileHandle.standardError.write(Data("KEY MOMENTS TEST FAILED: \(error)\n".utf8))
            exit(1)
        }
    }

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            FileHandle.standardError.write(Data("KEY MOMENTS TEST FAILED: \(message)\n".utf8))
            exit(1)
        }
    }

    static func run() async throws {
        schemaAndPrompts()
        validation()
        selection()
        approximateTimes()
        chunking()
        try await engine()
        placement()
        try persistence()
    }

    // Records each prompt and answers from a script, so the engine can be checked without a model.
    final class Script: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var prompts: [String] = []
        private let answer: (String, Int) -> String
        init(_ answer: @escaping (String, Int) -> String) { self.answer = answer }
        func reply(_ prompt: String) -> String {
            lock.lock()
            prompts.append(prompt)
            let call = prompts.count
            lock.unlock()
            return answer(prompt, call)
        }
        var count: Int { lock.lock(); defer { lock.unlock() }; return prompts.count }
    }

    static func units(count: Int, every seconds: Double = 3, text: String = "Steady speech about the lecture topic.") -> [KeyMomentUnit] {
        (0..<count).map { KeyMomentUnit(id: $0, start: Double($0) * seconds, text: "\(text) Number \($0).", approximate: false) }
    }

    static func schemaAndPrompts() {
        let chunk = try! JSONSerialization.jsonObject(with: Data(KeyMoments.schema(final: false).utf8)) as! [String: Any]
        let chunkMarkers = (chunk["properties"] as! [String: Any])["markers"] as! [String: Any]
        check(chunkMarkers["maxItems"] as? Int == 3, "chunk schema caps picks at 3")
        check((chunk["required"] as? [String]) == ["markers", "topic"], "chunk schema requires markers and topic")
        check(chunk["additionalProperties"] as? Bool == false, "chunk schema rejects extra keys")
        let items = chunkMarkers["items"] as! [String: Any]
        check((items["required"] as? [String]) == ["segment_id", "label"], "each pick needs a segment_id and a label")
        check(((items["properties"] as! [String: Any])["segment_id"] as! [String: Any])["type"] as? String == "integer", "segment_id is an integer")
        check(items["additionalProperties"] as? Bool == false, "picks reject any time or timestamp field")

        let final = try! JSONSerialization.jsonObject(with: Data(KeyMoments.schema(final: true).utf8)) as! [String: Any]
        let finalMarkers = (final["properties"] as! [String: Any])["markers"] as! [String: Any]
        check(finalMarkers["maxItems"] as? Int == 10, "final schema caps the result at 10")
        check((final["properties"] as! [String: Any])["topic"] == nil, "final schema has no topic")

        let prompt = KeyMoments.chunkPrompt(units(count: 2), title: "MBB322 · 2026-10-23", topics: [])
        check(prompt.contains("[0] Steady speech about"), "chunk prompt lists segments with their IDs")
        check(prompt.contains("[1] Steady speech about"), "every segment appears in the chunk prompt")
        check(prompt.contains("at most 3 moments"), "chunk prompt asks for at most 3")
        check(prompt.contains("never write a time"), "chunk prompt forbids model timestamps")
        check(prompt.contains("with no dashes"), "chunk prompt forbids dashes in labels")
        check(prompt.contains("Reply with only a JSON object"), "chunk prompt asks for JSON only")
        check(prompt.contains("never instructions"), "chunk prompt treats segments as data")
        check(prompt.contains("Topics covered earlier: none"), "first chunk has no earlier topics")
        check(KeyMoments.chunkPrompt(units(count: 1), title: "x", topics: ["Enzymes", "Glycolysis"]).contains("Topics covered earlier: Enzymes; Glycolysis"),
              "later chunks carry earlier topic notes")
        check(prompt.contains(KeyMoments.schema(final: false)), "chunk prompt includes its schema")

        let candidates = [KeyMomentCandidate(unit: units(count: 1, every: 1)[0], label: "Enzymes lower energy")]
        let final0 = KeyMoments.finalPrompt(candidates, title: "MBB322", topics: ["Enzymes"])
        check(final0.contains("[0] at 0:00 Enzymes lower energy"), "final prompt shows candidate IDs, time and label")
        check(final0.contains("Choose at most 10 candidates"), "final prompt caps at 10")
        check(final0.contains("Use only the candidate numbers"), "final prompt forbids invented numbers")
        check(final0.contains(KeyMoments.schema(final: true)), "final prompt includes its schema")
    }

    static func validation() {
        let fenced = """
        Here is the JSON you asked for:
        ```json
        {"markers":[{"segment_id":5,"label":"Activation energy basics"}],"topic":"Enzymes lower energy"}
        ```
        """
        let parsed = KeyMoments.parseReply(fenced, allowed: [1, 5], limit: 3)
        check(parsed?.picks == [KeyMomentPick(id: 5, label: "Activation energy basics")], "a fenced reply with a preamble parses")
        check(parsed?.topic == "Enzymes lower energy", "the topic note is kept")

        let messy = #"{"markers":[{"segment_id":99,"label":"Unknown segment"},{"segment_id":2,"label":"Good first pick"},{"segment_id":2,"label":"Duplicate of two"},{"segment_id":"3","label":"String id works"},{"segment_id":true,"label":"Boolean is no id"},{"segment_id":4,"label":"Fourth valid pick"},{"segment_id":6,"label":"Too late here"}]}"#
        let picks = KeyMoments.parseReply(messy, allowed: [2, 3, 4, 5], limit: 10)?.picks.map(\.id)
        check(picks == [2, 3, 4], "unknown IDs, duplicates and booleans are dropped; numeric strings are accepted")
        check(KeyMoments.parseReply(messy, allowed: [2, 3, 4], limit: 1)?.picks.count == 1, "the per-reply limit holds")

        check(KeyMoments.parseReply("I could not find any moments.", allowed: [1], limit: 3) == nil, "a reply with no JSON is rejected")
        check(KeyMoments.parseReply(#"{"topic":"no markers key"}"#, allowed: [1], limit: 3) == nil, "a reply without markers is rejected")
        check(KeyMoments.parseReply(#"{"markers":[]}"#, allowed: [1], limit: 3)?.picks.isEmpty == true, "an empty, valid answer is accepted")

        check(KeyMoments.cleanLabel("Pre-Columbian ecology") == "Pre Columbian ecology", "dashes become spaces and count as words")
        check(KeyMoments.cleanLabel("\u{201C}Fire and land\u{201D}.") == "Fire and land", "quotes and edge punctuation are trimmed")
        check(KeyMoments.cleanLabel("Fire \u{2014} land use") == "Fire land use", "an em dash never survives")
        check(KeyMoments.cleanLabel("One") == nil, "a one word label is rejected")
        check(KeyMoments.cleanLabel("one two three four five six") == nil, "a six word label is rejected")
        check(KeyMoments.cleanLabel("  --  ") == nil, "a label of dashes is rejected")
        check(KeyMoments.cleanLabel("Brackets [mark] here") == "Brackets mark here", "Markdown breakers are removed")
        check(KeyMoments.cleanLabel(String(repeating: "word ", count: 3) + String(repeating: "x", count: 70)) == nil, "a very long label is rejected")
        check(KeyMoments.cleanTopic("Enzymes - a review") == "Enzymes a review", "topic notes lose their dashes")
        check(KeyMoments.cleanTopic("   ") == nil, "a blank topic note is dropped")
        check(KeyMoments.headerLength("# x\n\n- Length: 63 min\n") == 3780, "the transcript header gives the lecture length")
        check(KeyMoments.headerLength("# x\n") == nil, "a transcript without a length has no header time")
    }

    static func selection() {
        func candidate(_ id: Int, _ t: Double, _ label: String) -> KeyMomentCandidate {
            KeyMomentCandidate(unit: KeyMomentUnit(id: id, start: t, text: "Opening words of segment \(id) go here.", approximate: false), label: label)
        }
        let spaced = KeyMoments.finish([candidate(3, 230, "Second close pick"), candidate(1, 30, "First early pick"),
                                        candidate(2, 40, "Too close pick"), candidate(4, 400, "Later distinct pick")],
                                       manualTimes: [], duration: 3600)
        check(spaced.map(\.t) == [30, 230, 400], "picks sort by time and the earlier of two close picks wins")
        check(spaced.allSatisfy { $0.anchor.hasPrefix("opening words of segment") && $0.anchor.split(separator: " ").count == 6 }, "each marker keeps the first six words of its segment as its anchor")

        let duplicates = KeyMoments.finish([candidate(1, 10, "Same label here"), candidate(1, 500, "Another label here"),
                                            candidate(2, 600, "same LABEL here")], manualTimes: [], duration: nil)
        check(duplicates.map(\.label) == ["Same label here"], "duplicate IDs and labels (any case) are dropped")

        let clamped = KeyMoments.finish([candidate(9, 5000, "Past the end")], manualTimes: [], duration: 3600)
        check(clamped.first?.t == 3600, "a time past the lecture end is clamped to its length")

        let manual = KeyMoments.finish([candidate(5, 230, "Near manual"), candidate(6, 300, "Clear of manual")],
                                       manualTimes: [200], duration: 3600)
        check(manual.map(\.label) == ["Clear of manual"], "AI markers within a minute of a manual marker are suppressed")

        // Eleven spaced picks: the closest pair is 130 seconds apart (200 and 330), so the later of that pair goes.
        let times: [Double] = [0, 200, 330, 500, 700, 900, 1100, 1300, 1500, 1700, 1900]
        let crowded = KeyMoments.finish(times.enumerated().map { candidate($0.offset, $0.element, "Label number \($0.offset)") },
                                        manualTimes: [], duration: nil)
        check(crowded.count == 10, "the cap is 10 markers")
        check(!crowded.map(\.t).contains(330) && crowded.map(\.t).contains(200), "the cap drops the later member of the closest pair")
        check(zip(crowded, crowded.dropFirst()).allSatisfy { $1.t - $0.t >= KeyMoments.minimumSpacing }, "kept markers stay 120 seconds apart")
    }

    static func approximateTimes() {
        let markdown = """
        # MBB322 — 2026-10-23

        - Date: 2026-10-23
        - Started: 16:13
        - Length: 60 min

        ## Transcript

        First sentence about enzymes. Second sentence keeps going for a while so the unit is long enough to read.

        > [0:12] Exam hint

        _No speech detected._

        The last paragraph covers chemiosmosis and the proton gradient in detail for the exam.
        """
        let units = KeyMoments.approximateUnits(markdown: markdown, duration: 3600)
        check(!units.isEmpty, "a transcript without timings still yields units")
        check(units.allSatisfy(\.approximate), "units from text position are marked approximate")
        check(units.first?.start == 0, "the first unit starts at zero")
        check(zip(units, units.dropFirst()).allSatisfy { $0.start < $1.start }, "approximate times increase through the text")
        check(units.last.map { $0.start < 3600 } == true, "approximate times stay inside the lecture")
        check(!units.contains { $0.text.contains("No speech") || $0.text.contains("Exam hint") }, "markers and no-speech lines are not units")
        check(units.map(\.id) == Array(0..<units.count), "IDs are sequential")
        check(KeyMoments.approximateUnits(markdown: markdown, duration: 0).isEmpty, "no duration, no approximate times")

        let saved = SavedSegments(segments: [.init(from: 0, to: 2000, text: " [BLANK_AUDIO] "), .init(from: 2000, to: 9000, text: " Hello class "),
                                             .init(from: 9000, to: 9500, text: "   "), .init(from: 9500, to: 12000, text: "Next idea")])
        let timed = KeyMoments.timedUnits(saved)
        check(timed.map(\.id) == [1, 3], "blank and bracketed sound tags are not units, and IDs stay the segment index")
        check(timed.map(\.start) == [2, 9.5] && timed.allSatisfy { !$0.approximate }, "timed units start at their saved millisecond offsets")
    }

    static func chunking() {
        // An hour at about 1 000 characters a minute: 1 080 segments of 3.5 seconds.
        let lecture = units(count: 1080, every: 3.5)
        let parts = KeyMoments.chunks(lecture)
        check((5...9).contains(parts.count), "an hour splits into about 6 to 8 parts, got \(parts.count)")
        check(parts.allSatisfy { part in part.reduce(0) { $0 + KeyMoments.chunkLine($1).count + 1 } <= KeyMoments.chunkCharacters + 1 }, "each part fits the character budget")
        check(Set(parts.flatMap { $0.map(\.id) }) == Set(lecture.map(\.id)), "every segment appears in at least one part")
        for (previous, next) in zip(parts, parts.dropFirst()) {
            guard let last = previous.last, let first = next.first else { continue }
            check(first.start < last.start, "consecutive parts overlap")
            check(last.start - first.start <= KeyMoments.chunkOverlap + 3, "the overlap is about 50 seconds")
        }
        check(KeyMoments.chunks([]).isEmpty, "no segments, no parts")
        check(KeyMoments.chunks(units(count: 1)).count == 1, "a single segment is one part")
    }

    static func engine() async throws {
        let lecture = units(count: 1080, every: 3.5)
        // Answers name only segment IDs and labels. The model's time never exists, so any time comes from the ID.
        let scripted = Script { prompt, _ in
            if prompt.contains("Candidates:") {
                let ids = prompt.split(separator: "\n").compactMap { line -> Int? in
                    guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
                    return Int(line[line.index(after: line.startIndex)..<close])
                }
                let picks = ids.prefix(10).map { #"{"segment_id":\#($0),"label":"Final pick number"}"# }
                return #"{"markers":["# + picks.joined(separator: ",") + "]}"
            }
            let body = prompt.components(separatedBy: "<segments>\n").last?.components(separatedBy: "\n</segments>").first ?? ""
            let ids = body.split(separator: "\n").compactMap { line -> Int? in
                guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
                return Int(line[line.index(after: line.startIndex)..<close])
            }
            let picks = [ids.first, ids.last].compactMap { $0 }.enumerated().map {
                #"{"segment_id":\#($0.element),"label":"Chunk pick \#($0.offset)"}"#
            }
            return #"{"markers":["# + picks.joined(separator: ",") + #"],"topic":"Steady lecture part"}"#
        }
        let markers = try await KeyMoments.find(units: lecture, duration: 3780, manualTimes: [], title: "MBB322",
            report: { _, _ in },
            complete: { prompt in scripted.reply(prompt) })
        check((1...10).contains(markers.count), "the scripted run keeps at most 10 markers, got \(markers.count)")
        check(zip(markers, markers.dropFirst()).allSatisfy { $1.t - $0.t >= KeyMoments.minimumSpacing }, "run output stays spaced")
        check(markers.allSatisfy { marker in lecture.contains { $0.start == marker.t } }, "every marker time is the start of a real segment")
        check(scripted.prompts.last?.contains("Candidates:") == true, "a final pass runs when candidates exceed the cap")

        // One bad reply, then a valid repair: the run recovers and still reports progress for each call.
        let repairing = Script { _, call in
            call == 1 ? "Sure, here are some moments." : #"{"markers":[{"segment_id":0,"label":"Opening framing today"}],"topic":"Intro"}"#
        }
        let steps = StepLog()
        let short = try await KeyMoments.find(units: units(count: 4), duration: 12, manualTimes: [], title: "x",
            report: { current, total in steps.add(current, total) },
            complete: { prompt in repairing.reply(prompt) })
        check(short.map(\.label) == ["Opening framing today"], "a repaired reply is used")
        check(repairing.count == 2 && repairing.prompts[1].contains("not valid JSON"), "one repair attempt carries the repair note")
        check(steps.values.count == 2 && steps.values.allSatisfy { $0 == (1, 2) }, "each attempt reports its step")

        let broken = Script { _, _ in "still not json" }
        do {
            _ = try await KeyMoments.find(units: units(count: 4), duration: 12, manualTimes: [], title: "x",
                report: { _, _ in }, complete: { prompt in broken.reply(prompt) })
            check(false, "two bad replies must fail")
        } catch {
            check(error as? KeyMomentError == .badReply, "two bad replies fail with a short, clear error")
        }
        check(broken.count == 2, "a bad part gets exactly one repair attempt")

        // A failed final pass falls back to the code selection rather than failing the run.
        let finalBroken = Script { prompt, _ in
            if prompt.contains("Candidates:") { return "no" }
            let body = prompt.components(separatedBy: "<segments>\n").last?.components(separatedBy: "\n</segments>").first ?? ""
            let ids = body.split(separator: "\n").compactMap { line -> Int? in
                guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
                return Int(line[line.index(after: line.startIndex)..<close])
            }
            return #"{"markers":[{"segment_id":\#(ids[0]),"label":"Only the first"}],"topic":"Topic"}"#
        }
        let fallback = try await KeyMoments.find(units: lecture, duration: 3780, manualTimes: [], title: "x",
            report: { _, _ in }, complete: { prompt in finalBroken.reply(prompt) })
        check(!fallback.isEmpty && fallback.count <= 10, "a failed final pass still returns moments")

        do {
            _ = try await KeyMoments.find(units: units(count: 4), duration: 12, manualTimes: [], title: "x",
                report: { _, _ in }, complete: { _ in throw CancellationError() })
            check(false, "cancellation must propagate")
        } catch {
            check(error is CancellationError, "cancellation is not turned into a bad reply")
        }

        do {
            _ = try await KeyMoments.find(units: [], duration: 12, manualTimes: [], title: "x", report: { _, _ in }, complete: { $0 })
            check(false, "no speech must fail")
        } catch {
            check(error as? KeyMomentError == .noSpeech, "an empty transcript reports no speech")
        }
    }

    final class StepLog: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var values: [(Int, Int)] = []
        func add(_ current: Int, _ total: Int) { lock.lock(); values.append((current, total)); lock.unlock() }
    }

    static func placement() {
        let paragraphs = [
            "Think of an enzyme as a way to make a reaction happen faster, without changing where it ends up.",
            "In glycolysis, hexokinase adds the first phosphate to glucose.",
            "The electron transport chain uses that energy to build a proton gradient."
        ]
        let markers = [
            AIMarker(t: 4, label: "Enzyme basics", anchor: KeyMoments.anchor("Think of an enzyme as a way")),
            AIMarker(t: 40, label: "Glycolysis start", anchor: KeyMoments.anchor("In glycolysis, hexokinase adds")),
            AIMarker(t: 300, label: "Chain energy", anchor: KeyMoments.anchor("The electron transport chain uses"))
        ]
        let placed = KeyMoments.placements(markers, paragraphs: paragraphs, duration: 600)
        check(placed[0]?.map(\.marker.label) == ["Enzyme basics"], "an anchor places its marker before its paragraph")
        check(placed[1]?.map(\.marker.label) == ["Glycolysis start"], "the second anchor finds the second paragraph")
        check(placed[2]?.map(\.marker.label) == ["Chain energy"], "the third anchor finds the third paragraph")
        check(placed[2]?.first?.index == 2, "placed markers keep their index in the sidecar")

        let equal = ["Alpha beta gamma delta.", "Epsilon zeta eta theta.", "Iota kappa lambda mu."]
        let timeOnly = KeyMoments.placements([AIMarker(t: 300, label: "Middle of talk", anchor: "")], paragraphs: equal, duration: 600)
        check(timeOnly[1]?.first?.marker.label == "Middle of talk", "without an anchor, the marker goes by its share of the lecture")
        let atEnd = KeyMoments.placements([AIMarker(t: 600, label: "At the end", anchor: "")], paragraphs: equal, duration: 600)
        check(atEnd[equal.count]?.first?.marker.label == "At the end", "a marker at the very end sits after the last paragraph")
        let noDuration = KeyMoments.placements([AIMarker(t: 300, label: "Unplaced", anchor: "")], paragraphs: equal, duration: nil)
        check(noDuration[equal.count] != nil, "without a duration or anchor, the marker goes to the end")

        let repeated = ["Same words here now and again.", "Something else entirely in this one.", "Same words here now and again."]
        let early = KeyMoments.placements([AIMarker(t: 10, label: "Repeated phrase", anchor: "same words here now and again")],
                                          paragraphs: repeated, duration: 600)
        check(early[0] != nil, "a repeated anchor prefers the match nearest its time, early")
        let late = KeyMoments.placements([AIMarker(t: 590, label: "Repeated phrase", anchor: "same words here now and again")],
                                         paragraphs: repeated, duration: 600)
        check(late[2] != nil, "a repeated anchor prefers the match nearest its time, late")
    }

    static func persistence() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("nosy-key-moments-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: root) }
        let paths = AppPaths(environment: ["NOSY_SUPPORT_DIR": root.appendingPathComponent("support").path,
                                          "NOSY_TRANSCRIPTS_DIR": root.appendingPathComponent("transcripts").path])
        try paths.prepareSupport()
        let folder = paths.lectureFolder("MBB322")
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let transcript = folder.appendingPathComponent("2026-10-23.md")
        try Data("# MBB322 — 2026-10-23\n\n- Date: 2026-10-23\n- Started: 16:13\n- Length: 60 min\n\n## Transcript\n\nHello there.\n".utf8).write(to: transcript)

        let started = Date(timeIntervalSince1970: 1_790_000_000)
        var record = SessionRecord(id: "20261023-161300", lecture: "MBB322", session: "2026-10-23", startedAt: started,
                                   endedAt: started, status: .done, transcriptPath: transcript.path,
                                   markers: [SessionMarker(t: 12, label: "Exam hint"), SessionMarker(t: 31, label: "Confused, review")])
        record.aiMarkers = [AIMarker(t: 60, label: "Enzymes lower energy", anchor: "think of an enzyme", approximate: false),
                            AIMarker(t: 400, label: "Chemiosmosis basics", anchor: "", approximate: true),
                            AIMarker(t: 900, label: "Exam practice tips", anchor: "", approximate: true)]
        try record.save(in: paths)
        let manual = record.markers

        let loaded = try SessionRecord.read(paths.audioFile(record.id, "json"))
        check(loaded == record, "AI markers round trip through the sidecar")
        check(Core.records(in: paths).count == 1, "the record lists once")

        try KeyMomentStore.remove(at: 1, transcript: transcript, paths: paths)
        let afterRemove = try SessionRecord.read(paths.audioFile(record.id, "json"))
        check(afterRemove.aiMarkers.map(\.label) == ["Enzymes lower energy", "Exam practice tips"], "removing one AI marker keeps the rest")
        check(afterRemove.markers == manual, "removing AI markers never touches manual markers")
        check(afterRemove.transcriptPath == transcript.path && afterRemove.status == .done, "other sidecar fields are kept")

        try KeyMomentStore.remove(at: 99, transcript: transcript, paths: paths)
        let unchanged = try SessionRecord.read(paths.audioFile(record.id, "json"))
        check(unchanged.aiMarkers.count == 2, "removing an index that is not there changes nothing")

        try KeyMomentStore.replace([AIMarker(t: 120, label: "Fresh set of picks", anchor: "")], transcript: transcript, paths: paths)
        let fresh = try SessionRecord.read(paths.audioFile(record.id, "json"))
        check(fresh.aiMarkers.map(\.label) == ["Fresh set of picks"], "a new run replaces AI markers")

        try KeyMomentStore.removeAll(transcript: transcript, paths: paths)
        let cleared = try SessionRecord.read(paths.audioFile(record.id, "json"))
        check(cleared.aiMarkers.isEmpty && cleared.markers == manual, "Remove AI markers clears only AI markers")

        // Sidecars from before this change have no aiMarkers key and still load.
        let old = #"{"id":"20261022-101000","lecture":"MBB322","session":"old","startedAt":"2026-10-22T10:10:00Z","status":"done","markers":[{"t":5,"label":"Old marker"}]}"#
        try Data(old.utf8).write(to: paths.audioFile("20261022-101000", "json"))
        let oldRecord = try SessionRecord.read(paths.audioFile("20261022-101000", "json"))
        check(oldRecord.aiMarkers.isEmpty && oldRecord.markers.first?.label == "Old marker", "old sidecars load with no AI markers and keep manual markers")

        // A damaged AI marker is dropped, not allowed to break the whole sidecar.
        let damaged = #"{"id":"20261021-101000","lecture":"MBB322","session":"damaged","startedAt":"2026-10-21T10:10:00Z","status":"done","aiMarkers":[{"t":-4,"label":"Negative time"},{"t":50,"label":"Kept marker","anchor":"kept words"}]}"#
        try Data(damaged.utf8).write(to: paths.audioFile("20261021-101000", "json"))
        let damagedRecord = try SessionRecord.read(paths.audioFile("20261021-101000", "json"))
        check(damagedRecord.aiMarkers.map(\.label) == ["Kept marker"] && damagedRecord.aiMarkers.first?.approximate == false, "a negative AI marker is dropped and defaults fill in")

        // The segments file sits beside the sidecar and is never mistaken for a record.
        let records = Core.records(in: paths).count
        let segments = SavedSegments(segments: [.init(from: 0, to: 1500, text: "Hello there.")])
        try JSONEncoder().encode(segments).write(to: KeyMoments.segmentsURL(id: record.id, paths: paths))
        check(Core.records(in: paths).count == records, "a segments file is not a record")
        check(KeyMoments.loadSegments(id: record.id, paths: paths) == segments, "saved segments load back unchanged")
        check(KeyMoments.isSegmentsFile(KeyMoments.segmentsURL(id: record.id, paths: paths)), "the segments file is recognized")

        // Text lines match Whisper segments one to one, so the saved text is the final text the reader shows.
        let json = Data(#"{"transcription":[{"offsets":{"from":0,"to":1500},"text":" raw one"},{"offsets":{"from":1500,"to":3000},"text":" raw two"}]}"#.utf8)
        let decoded = try JSONDecoder().decode(TranscriptSegments.self, from: json)
        try KeyMoments.saveSegments(decoded.transcription, text: "Final one.\nFinal two.\n", id: "aligned", paths: paths)
        let aligned = KeyMoments.loadSegments(id: "aligned", paths: paths)
        check(aligned?.segments.map(\.text) == ["Final one.", "Final two."], "aligned lines give the final text")
        try KeyMoments.saveSegments(decoded.transcription, text: "Only one line.\n", id: "misaligned", paths: paths)
        check(KeyMoments.loadSegments(id: "misaligned", paths: paths)?.segments.map(\.text) == ["raw one", "raw two"],
              "misaligned text falls back to Whisper's own segment text")

        // A plan needs the record; without one, nothing is saved and the user sees a short reason.
        let orphan = folder.appendingPathComponent("orphan.md")
        try Data("# x\n\n- Length: 5 min\n\n## Transcript\n\nWords here.\n".utf8).write(to: orphan)
        do {
            _ = try KeyMoments.plan(transcript: orphan, paths: paths)
            check(false, "a transcript without a record has no plan")
        } catch {
            check(error as? KeyMomentError == .noRecord, "a transcript without a recording says so")
        }
        do {
            try KeyMomentStore.replace([], transcript: orphan, paths: paths)
            check(false, "a transcript without a record cannot store markers")
        } catch {
            check(error as? KeyMomentError == .noRecord, "storing without a record is refused")
        }
    }

    // Uses the installed Qwen3 4B through the bundled helper. Prints timings and the markers; writes nothing.
    static func realRun(_ path: String) async throws {
        let environment = ProcessInfo.processInfo.environment
        let model = environment["NOSY_QWEN_MODEL"] ?? "\(NSHomeDirectory())/Library/Application Support/Nosy/models/llm/Qwen3-4B-Instruct-2507-Q4_K_M.gguf"
        let helper = environment["NOSY_LLAMA_HELPER"] ?? "vendor/llama/nosy-llama"
        let markdown = try String(contentsOfFile: path, encoding: .utf8)
        let duration = KeyMoments.headerLength(markdown) ?? 3600
        let units = KeyMoments.approximateUnits(markdown: markdown, duration: duration)
        let parts = KeyMoments.chunks(units).count
        print("REAL RUN: \(units.count) units in \(parts) parts; lecture \(Int(duration / 60)) min; approximate times")
        var configured = SummaryRequest(provider: .qwen, model: model, executable: URL(fileURLWithPath: helper))
        configured.outputTokens = KeyMoments.outputTokens
        let request = configured
        let job = TranscriptionJob()
        let started = Date()
        let markers = try await KeyMoments.find(units: units, duration: duration, manualTimes: [], title: "real run",
            report: { current, total in print("  step \(current) of \(total) at \(String(format: "%.1f", Date().timeIntervalSince(started)))s") },
            complete: { prompt in
                let callStart = Date()
                let reply = try await SummaryRunner.run(prompt, request: request, job: job)
                print("  call finished in \(String(format: "%.1f", Date().timeIntervalSince(callStart)))s, \(reply.count) characters")
                return reply
            })
        print("REAL RUN TOTAL: \(String(format: "%.1f", Date().timeIntervalSince(started)))s, \(markers.count) markers")
        for marker in markers {
            print("  \(Core.timer(marker.t))  \(marker.label)   [anchor: \(marker.anchor)]")
        }
    }
}
