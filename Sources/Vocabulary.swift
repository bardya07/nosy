import Foundation

// Match whisper.cpp's native tokenizer; character limits don't bound its prompt tokens.
enum Vocabulary {
    static let tokenBudget = 160

    static func modelVocabulary(_ model: URL) -> Set<Data>? {
        guard let data = try? Data(contentsOf: model, options: .mappedIfSafe) else { return nil }
        var offset = 0
        func integer() -> Int? {
            guard offset <= data.count - 4 else { return nil }
            defer { offset += 4 }
            return Int(data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) })
        }
        guard integer() == 0x67676d6c else { return nil }
        offset += 11 * 4
        guard let mel = integer(), let fft = integer(), mel > 0, fft > 0,
              mel <= (data.count - offset) / 4 / fft else { return nil }
        offset += mel * fft * 4
        guard let count = integer(), count > 0, count <= (data.count - offset) / 4 else { return nil }
        var vocabulary = Set<Data>()
        for _ in 0..<count {
            guard let length = integer(), length <= data.count - offset else { return nil }
            vocabulary.insert(data.subdata(in: offset..<(offset + length)))
            offset += length
        }
        return vocabulary
    }

    static func entries(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0.isNewline }).map { Core.collapseWhitespace(String($0)) }.filter { !$0.isEmpty }
    }
    static func prompt(_ text: String, model: URL) -> (text: String, tokens: Int)? {
        guard let vocabulary = modelVocabulary(model) else { return nil }
        return prompt(entries(text), vocabulary: vocabulary)
    }
    static func prompt(_ text: String, vocabulary: Set<Data>) -> (text: String, tokens: Int)? {
        prompt(entries(text), vocabulary: vocabulary)
    }
    static func prompt(_ terms: [String], vocabulary: Set<Data>) -> (text: String, tokens: Int)? {
        // C-locale character classes, as used by whisper.cpp (including for UTF-8 terms).
        let pattern = #"'s|'t|'re|'ve|'m|'ll|'d| ?[A-Za-z]+| ?[0-9]+| ?[^ \t\n\r\f\vA-Za-z0-9]+|[ \t\n\r\f\v]+(?![^ \t\n\r\f\v])|[ \t\n\r\f\v]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let longest = vocabulary.map(\.count).max() ?? 0
        func count(_ text: String) -> Int? {
            var count = 0
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range, in: text) else { return nil }
                let bytes = Data(text[range].utf8)
                var start = 0
                while start < bytes.count {
                    var end = min(bytes.count, start + longest)
                    while end > start, !vocabulary.contains(bytes.subdata(in: start..<end)) { end -= 1 }
                    guard end > start else { return nil }
                    count += 1
                    if count > tokenBudget { return count }
                    start = end
                }
            }
            return count
        }
        var result = "", tokens = 0
        for term in terms {
            let term = Core.collapseWhitespace(String(term))
            if term.isEmpty { continue }
            let candidate = result.isEmpty ? term : result + ", " + term
            guard let size = count(candidate), size <= tokenBudget else { break }
            result = candidate
            tokens = size
        }
        return tokens > 0 ? (result, tokens) : nil
    }
}
