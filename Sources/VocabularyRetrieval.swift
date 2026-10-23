import Foundation

// Search keys are retrieval evidence only. They never grant permission to rewrite text.
enum VocabularySimilarity {
    static func key(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .filter { $0.isLetter || $0.isNumber }
    }
    static func phonetic(_ text: String) -> String {
        var value = key(text)
        for (from, to) in [("ph", "f"), ("th", "0"), ("ch", "x"), ("sh", "x"), ("qu", "k"), ("ck", "k"), ("dg", "j"), ("c", "k"), ("q", "k"), ("z", "s"), ("v", "f"), ("y", "i")] {
            value = value.replacingOccurrences(of: from, with: to)
        }
        var result = "", previous: Character?
        for (index, char) in value.enumerated() {
            if index > 0 && "aeiouh".contains(char) { continue }
            if char != previous { result.append(char); previous = char }
        }
        return result
    }
    static func similarity(_ a: String, _ b: String) -> Double {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty || !b.isEmpty else { return 1 }
        var row = Array(0...b.count)
        for (i, char) in a.enumerated() {
            var next = [i + 1]
            for (j, other) in b.enumerated() { next.append(min(next[j] + 1, row[j + 1] + 1, row[j] + (char == other ? 0 : 1))) }
            row = next
        }
        return 1 - Double(row.last!) / Double(max(a.count, b.count))
    }
    static func grams(_ key: String) -> Set<String> {
        let chars = Array(key)
        guard chars.count >= 2 else { return [key] }
        return Set((0..<(chars.count - 1)).map { String(chars[$0...($0 + 1)]) })
    }
    static func risky(_ term: String) -> Bool {
        let letters = term.filter(\.isLetter)
        let symbols = term.components(separatedBy: .alphanumerics.inverted).filter { !$0.isEmpty }
        return symbols.contains { $0.count <= 4 && $0.contains(where: \.isLetter) && $0 == $0.uppercased() }
            || key(term).count < 5 || term.contains(where: \.isNumber)
            || (!letters.isEmpty && letters == letters.uppercased())
            || ["alpha", "beta", "gamma", "delta", "theta", "sigma", "lambda", "nano", "pico", "gray"].contains(key(term))
    }
}

struct VocabularyCandidate: Codable, Sendable {
    let term: String
    let source: String
    let location: Int
    let length: Int
    let spelling: Double
    let phonetic: Double
    let margin: Double
    var range: NSRange { NSRange(location: location, length: length) }
}

struct VocabularyIndex: Sendable {
    private let terms: [String]
    private let keys: [String]
    private let exact: Set<String>
    private let phones: [String]
    private let postings: [String: [Int]]
    private let phoneticPostings: [String: [Int]]
    private let queryCache = VocabularyQueryCache()

    init(terms: [String]) {
        self.terms = Array(Set(terms)).sorted()
        keys = self.terms.map(VocabularySimilarity.key)
        exact = Set(keys)
        phones = self.terms.map(VocabularySimilarity.phonetic)
        var postings: [String: [Int]] = [:], phoneticPostings: [String: [Int]] = [:]
        for i in keys.indices {
            for gram in VocabularySimilarity.grams(keys[i]) { postings[gram, default: []].append(i) }
            phoneticPostings[phones[i], default: []].append(i)
        }
        self.postings = postings
        self.phoneticPostings = phoneticPostings
    }
    func retrieve(_ text: String, limit: Int = 24) -> [VocabularyCandidate] {
        guard let regex = try? NSRegularExpression(pattern: #"[\p{L}\p{N}]+(?:['’\-][\p{L}\p{N}]+)*"#) else { return [] }
        let words = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        let ns = text as NSString
        var found: [VocabularyCandidate] = []
        for start in words.indices {
            for size in 1...min(4, words.count - start) {
                let range = NSRange(location: words[start].range.location, length: NSMaxRange(words[start + size - 1].range) - words[start].range.location)
                let source = ns.substring(with: range), key = VocabularySimilarity.key(source), phone = VocabularySimilarity.phonetic(source)
                // Newlines separate Whisper segments and are also marker insertion
                // boundaries. Never retrieve a correction that crosses one.
                guard !source.contains(where: \.isNewline) else { continue }
                guard key.count >= 5, key.count <= 60 else { continue }
                // Exact canonical words cannot trigger retries, including their plural forms.
                if exact.contains(key) || (key.hasSuffix("s") && exact.contains(String(key.dropLast()))) { continue }
                guard phoneticPostings[phone] != nil else { continue }
                if let cached = queryCache.get(key) {
                    if let hit = cached.first {
                        found.append(.init(term: hit.term, source: source, location: range.location, length: range.length, spelling: hit.spelling, phonetic: hit.phonetic, margin: hit.margin))
                    }
                    continue
                }
                var votes: [Int: Int] = [:]
                for gram in VocabularySimilarity.grams(key) { for id in postings[gram] ?? [] { votes[id, default: 0] += 1 } }
                for id in phoneticPostings[phone] ?? [] { votes[id, default: 0] += 20 }
                let ids = votes.keys.sorted { votes[$0] == votes[$1] ? $0 < $1 : votes[$0]! > votes[$1]! }.prefix(64)
                var ranked: [(Int, Double, Double, Double)] = []
                for id in ids {
                    guard !VocabularySimilarity.risky(terms[id]) else { continue }
                    let ratio = Double(keys[id].count) / Double(key.count)
                    guard ratio >= 0.5, ratio <= 2 else { continue }
                    let sourceWords = VocabularyAcceptance.words(source).joined(separator: " ")
                    let termWords = VocabularyAcceptance.words(terms[id]).joined(separator: " ")
                    if (" " + sourceWords + " ").contains(" " + termWords + " ") { continue }
                    let spelling = VocabularySimilarity.similarity(key, keys[id])
                    let phonetic = VocabularySimilarity.similarity(phone, phones[id])
                    guard spelling >= 0.75 || (phonetic >= 0.8 && spelling >= 0.5) else { continue }
                    ranked.append((id, spelling, phonetic, max(spelling, phonetic * 0.95)))
                }
                ranked.sort { $0.3 == $1.3 ? terms[$0.0] < terms[$1.0] : $0.3 > $1.3 }
                guard let best = ranked.first else { queryCache.put(key, []); continue }
                let hit = VocabularyCandidate(term: terms[best.0], source: source, location: range.location, length: range.length,
                                              spelling: best.1, phonetic: best.2, margin: best.3 - (ranked.dropFirst().first?.3 ?? 0))
                queryCache.put(key, [hit])
                found.append(hit)
            }
        }
        return Array(found.sorted {
            let a = max($0.spelling, $0.phonetic * 0.95) + $0.margin * 0.1
            let b = max($1.spelling, $1.phonetic * 0.95) + $1.margin * 0.1
            return a == b ? ($0.location, $0.term) < ($1.location, $1.term) : a > b
        }.prefix(limit))
    }
}

struct VocabularyEdit: Codable, Sendable {
    let source: String
    let replacement: String
    let location: Int
    let length: Int
    let method: String
}

enum VocabularyAcceptance {
    static func words(_ text: String) -> [String] {
        text.lowercased().components(separatedBy: .alphanumerics.inverted).filter { !$0.isEmpty }
    }
    static func loops(_ text: String) -> Bool {
        let words = words(text)
        guard words.count >= 12 else { return false }
        for size in 3...min(16, words.count / 3) {
            for start in 0...(words.count - size * 3) {
                let phrase = Array(words[start..<(start + size)])
                if phrase == Array(words[(start + size)..<(start + 2 * size)]) && phrase == Array(words[(start + 2 * size)..<(start + 3 * size)]) { return true }
            }
        }
        return false
    }
    static func safe(_ candidate: VocabularyCandidate, confidence: Double?) -> Bool {
        guard let confidence, confidence < 0.65,
              !VocabularySimilarity.risky(candidate.term), !VocabularySimilarity.risky(candidate.source),
              words(candidate.source).count == words(candidate.term).count else { return false }
        return candidate.phonetic == 1 && candidate.spelling >= 0.85 && candidate.margin >= 0.15
    }
    static func edits(original: String, candidates: [VocabularyCandidate], confidence: (NSRange) -> Double?) -> [VocabularyEdit] {
        guard !loops(original) else { return [] }
        var edits: [VocabularyEdit] = []
        let ns = original as NSString
        for c in candidates where safe(c, confidence: confidence(c.range)) {
            guard c.location >= 0, c.length > 0, NSMaxRange(c.range) <= ns.length,
                  ns.substring(with: c.range) == c.source,
                  !edits.contains(where: { NSIntersectionRange(NSRange(location: $0.location, length: $0.length), c.range).length > 0 }) else { continue }
            edits.append(.init(source: c.source, replacement: c.term, location: c.location, length: c.length, method: "phonetic"))
        }
        return edits
    }
    static func applying(_ edits: [VocabularyEdit], to text: String) -> String {
        var result = text as NSString
        for edit in edits.sorted(by: { $0.location > $1.location }) {
            result = result.replacingCharacters(in: NSRange(location: edit.location, length: edit.length), with: edit.replacement) as NSString
        }
        return result as String
    }
}

private final class VocabularyQueryCache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: [VocabularyCandidate]] = [:]
    func get(_ key: String) -> [VocabularyCandidate]? { lock.lock(); defer { lock.unlock() }; return values[key] }
    func put(_ key: String, _ value: [VocabularyCandidate]) {
        lock.lock(); defer { lock.unlock() }
        if values.count >= 20_000 { values.removeAll() }
        values[key] = value
    }
}
