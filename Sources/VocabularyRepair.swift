import AVFoundation
import Foundation

struct VocabularyStages: Sendable {
    var router = true
    var redecode = true
    var trie = false
    var substitute = true
    var requireConfidence = false
    static func internalFlags(_ value: String) -> Self {
        let flags = Set(value.split(separator: ",").map(String.init))
        return Self(router: flags.contains("router"), redecode: flags.contains("redecode"), trie: flags.contains("trie"), substitute: flags.contains("substitute"), requireConfidence: flags.contains("confidence"))
    }
}

struct VocabularyDocument: Decodable, Sendable {
    struct Segment: Decodable, Sendable {
        struct Offsets: Decodable, Sendable { let from: Int; let to: Int }
        struct Token: Decodable, Sendable { let text: String; let id: Int; let p: Double }
        let text: String
        let offsets: Offsets
        let tokens: [Token]
    }
    let transcription: [Segment]
    struct Window: Sendable {
        let id: Int
        let start: Double
        let end: Double
        let text: String
        let tokens: [(NSRange, Double)]
        func confidence(_ range: NSRange) -> Double? {
            let matching = tokens.filter { NSIntersectionRange($0.0, range).length > 0 }
            guard !matching.isEmpty else { return nil }
            return exp(matching.reduce(0) { $0 + log(max(1e-9, $1.1)) } / Double(matching.count))
        }
    }
    var windows: [Window] {
        var groups: [[Segment]] = []
        for segment in transcription {
            if let last = groups.last, let first = last.first,
               segment.offsets.to - first.offsets.from <= 28_000 {
                groups[groups.count - 1].append(segment)
            } else { groups.append([segment]) }
        }
        return groups.enumerated().map { id, segments in
            var text = "", tokens: [(NSRange, Double)] = []
            for segment in segments {
                let clean = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let lexical = segment.tokens.filter { $0.id < 50257 }
                let assembled = lexical.map(\.text).joined()
                let leading = (segment.text as NSString).range(of: clean).location
                var position = text.utf16.count - (leading == NSNotFound ? 0 : leading)
                if assembled == segment.text {
                    for token in lexical {
                        let range = NSRange(location: max(0, position), length: max(0, token.text.utf16.count + min(0, position)))
                        if !token.text.trimmingCharacters(in: .alphanumerics.inverted).isEmpty { tokens.append((range, token.p)) }
                        position += token.text.utf16.count
                    }
                }
                text += clean + "\n"
            }
            return Window(id: id, start: Double(segments.first!.offsets.from) / 1000,
                          end: Double(segments.last!.offsets.to) / 1000, text: text, tokens: tokens)
        }
    }
}

private final class VocabularyIndexCache: @unchecked Sendable {
    static let shared = VocabularyIndexCache()
    private let lock = NSLock()
    private var values: [String: VocabularyIndex] = [:]
    func index(terms: [String]) -> VocabularyIndex {
        let key = terms.sorted().joined(separator: "\n")
        lock.lock(); defer { lock.unlock() }
        if let value = values[key] { return value }
        let index = VocabularyIndex(terms: terms)
        if values.count >= 8 { values.removeAll() }
        values[key] = index
        return index
    }
}

enum VocabularyRepair {
    struct Request: Codable, Sendable {
        let id: Int
        let audio: String
        let prompt: String
        let candidates: [String]
        let bias: Bool
    }
    struct Result: Codable, Sendable {
        let id: Int
        let text: String
        let status: Int
        let seconds: Double
        let tokens: Int
        let promptTokens: Int
    }
    struct Proposal: Codable, Sendable {
        let id: Int
        let start: Double
        let end: Double
        let text: String
        let candidates: [VocabularyCandidate]
    }
    struct Plan: Sendable {
        let windows: [VocabularyDocument.Window]
        let proposals: [Proposal]
        let requests: [Request]
        let route: SubjectCatalog.Route
    }
    static func prepare(document: VocabularyDocument, wav: URL, directory: URL, model: URL, userTerms: [String],
                        catalog: SubjectCatalog, subjects: [String], stages: VocabularyStages,
                        job: TranscriptionJob = TranscriptionJob()) throws -> Plan {
        let windows = document.windows
        let eligible = catalog.eligible(subjects: subjects)
        let route = catalog.route(text: windows.map(\.text).joined(), eligible: eligible)
        let selected = stages.router && !route.selected.isEmpty ? Set(route.selected).union(eligible.intersection(["stem-core"])) : eligible
        let index = VocabularyIndexCache.shared.index(terms: catalog.terms(packs: selected) + userTerms)
        let tokenizer = stages.redecode ? Vocabulary.modelVocabulary(model) : nil
        var proposals: [Proposal] = [], requests: [Request] = []
        let input = stages.redecode ? try AVAudioFile(forReading: wav, commonFormat: .pcmFormatFloat32, interleaved: false) : nil
        for window in windows {
            try job.checkCancellation()
            let candidates = index.retrieve(window.text)
            proposals.append(.init(id: window.id, start: window.start, end: window.end, text: window.text, candidates: candidates))
            guard stages.redecode, let input, let tokenizer, window.end > window.start, window.end - window.start <= 29,
                  candidates.contains(where: { (window.confidence($0.range) ?? 1) < 0.65 }) else { continue }
            let terms = Array(NSOrderedSet(array: userTerms + candidates.map(\.term))) as? [String] ?? userTerms
            guard let prompt = Vocabulary.prompt(terms, vocabulary: tokenizer) else { continue }
            let start = max(0, window.start - 0.2), end = min(Double(input.length) / 16000, window.end + 0.2)
            guard end > start, end - start <= 30, input.processingFormat.sampleRate == 16000, input.processingFormat.channelCount == 1,
                  let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: AVAudioFrameCount((end - start) * 16000)) else { continue }
            input.framePosition = AVAudioFramePosition(start * 16000)
            try input.read(into: buffer)
            guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { continue }
            let audio = directory.appendingPathComponent("window-\(window.id).f32")
            try Data(bytes: samples, count: Int(buffer.frameLength) * 4).write(to: audio)
            // Trie and prompt are separate arms; user terms keep priority in prompted retries.
            requests.append(.init(id: window.id, audio: audio.path, prompt: stages.trie ? "" : prompt.text,
                                  candidates: candidates.map(\.term), bias: stages.trie))
        }
        return Plan(windows: windows, proposals: proposals, requests: requests, route: route)
    }
    static func apply(plan: Plan, results: [Result], stages: VocabularyStages) -> (text: String, edits: [VocabularyEdit]) {
        var text = "", all: [VocabularyEdit] = []
        let results = Dictionary(results.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (window, proposal) in zip(plan.windows, plan.proposals) {
            let result = results[window.id]
            let retry = stages.redecode && result?.status == 0 && (result?.tokens ?? 220) < 220 ? result?.text : nil
            var edits = VocabularyAcceptance.edits(original: window.text, retry: retry, candidates: proposal.candidates,
                                                   confidence: window.confidence, substitute: stages.substitute, requireConfidence: stages.requireConfidence)
            if stages.substitute, retry != nil {
                let leftovers = proposal.candidates.filter { candidate in !edits.contains { NSIntersectionRange(candidate.range, NSRange(location: $0.location, length: $0.length)).length > 0 } }
                edits += VocabularyAcceptance.edits(original: window.text, retry: nil, candidates: leftovers, confidence: window.confidence, substitute: true)
            }
            all += edits.map { .init(source: $0.source, replacement: $0.replacement, location: $0.location + text.utf16.count, length: $0.length, method: $0.method) }
            text += window.text
        }
        return (VocabularyAcceptance.applying(all, to: text), all)
    }
    static func run(json: URL, original: String, wav: URL, base: URL, paths: AppPaths, lecture: String,
                    settings: SubjectSettings, userTerms: [String], stages: VocabularyStages, job: TranscriptionJob) throws -> String {
        let directory = base.appendingPathExtension("vocabulary")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = try JSONDecoder().decode(VocabularyDocument.self, from: Data(contentsOf: json))
        guard document.windows.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines) == original.trimmingCharacters(in: .whitespacesAndNewlines) else { return original }
        let plan = try prepare(document: document, wav: wav, directory: directory, model: paths.model, userTerms: userTerms,
                               catalog: .bundled, subjects: settings.resolved(course: lecture), stages: stages, job: job)
        let requests = directory.appendingPathComponent("requests.json"), output = directory.appendingPathComponent("results.json")
        var results: [Result] = []
        if !plan.requests.isEmpty {
            let worker = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("NosyVocabularyWorker")
            guard FileManager.default.isExecutableFile(atPath: worker.path) else { return original }
            try JSONEncoder().encode(plan.requests).write(to: requests)
            let process = Process()
            process.qualityOfService = .utility
            process.executableURL = worker
            process.arguments = [paths.model.path, requests.path, output.path]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try job.launch(process); process.waitUntilExit(); try job.checkCancellation()
            guard process.terminationStatus == 0 else { return original }
            results = try JSONDecoder().decode([Result].self, from: Data(contentsOf: output))
        }
        let applied = apply(plan: plan, results: results, stages: stages)
        // Local, separate from session discovery; preserve baseline and exact accepted edits.
        let ledger = paths.support.appendingPathComponent("routing", isDirectory: true)
        try FileManager.default.createDirectory(at: ledger, withIntermediateDirectories: true)
        let record: [String: Any] = ["baseline": original, "edits": try JSONSerialization.jsonObject(with: JSONEncoder().encode(applied.edits)),
                                     "packs": plan.route.selected, "schemaVersion": 1]
        try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]).write(to: ledger.appendingPathComponent(base.lastPathComponent + ".json"), options: .atomic)
        return applied.edits.isEmpty ? original : applied.text
    }
}
