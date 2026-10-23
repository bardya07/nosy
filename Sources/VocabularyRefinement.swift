import Foundation

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

enum VocabularyRefinement {
    struct Output: Codable, Sendable {
        let text: String
        let edits: [VocabularyEdit]
        let route: SubjectCatalog.Route
    }
    static func refine(original: String, data: Data, catalog: SubjectCatalog, subjects: [String], userTerms: [String],
                       router: Bool = true, substitute: Bool = true, job: TranscriptionJob = TranscriptionJob()) throws -> Output {
        let document = try JSONDecoder().decode(VocabularyDocument.self, from: data)
        let windows = document.windows
        let baseline = windows.map(\.text).joined()
        let eligible = catalog.eligible(subjects: subjects)
        let route = catalog.route(text: original, eligible: eligible)
        guard baseline == original else { return Output(text: original, edits: [], route: route) }
        let selected = router && !route.selected.isEmpty ? Set(route.selected).union(eligible.intersection(["stem-core"])) : eligible
        let index = VocabularyIndexCache.shared.index(terms: catalog.terms(packs: selected) + userTerms)
        var edits: [VocabularyEdit] = [], position = 0
        for window in windows {
            try job.checkCancellation()
            if substitute {
                let candidates = index.retrieve(window.text)
                edits += VocabularyAcceptance.edits(original: window.text, candidates: candidates, confidence: window.confidence)
                    .map { .init(source: $0.source, replacement: $0.replacement, location: $0.location + position, length: $0.length, method: $0.method) }
            }
            position += window.text.utf16.count
        }
        return Output(text: VocabularyAcceptance.applying(edits, to: original), edits: edits, route: route)
    }
    static func save(_ output: Output, baseline: String, id: String, paths: AppPaths) throws {
        let directory = paths.support.appendingPathComponent("routing", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let record: [String: Any] = ["baseline": baseline, "edits": try JSONSerialization.jsonObject(with: JSONEncoder().encode(output.edits)),
                                     "packs": output.route.selected, "schemaVersion": 1]
        try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]).write(to: directory.appendingPathComponent(id + ".json"), options: .atomic)
    }
}
