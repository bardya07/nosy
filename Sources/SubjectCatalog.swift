import Foundation

struct SubjectSettings: Codable, Equatable, Sendable {
    var schemaVersion = 1
    // "auto", "general", or a stable subject ID. An explicit choice always wins.
    var subject = "auto"
    // Read legacy secondary choices without discarding an existing folder setting.
    var additionalSubject = ""
    var canonicalSubject: String { Self.canonicalID(subject) }
    var isEnabled: Bool { canonicalSubject != "general" }

    static func load(folder: URL) throws -> Self {
        let url = folder.appendingPathComponent("vocabulary.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
        let stored = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        let settings = stored.migrated()
        guard settings.schemaVersion == 1,
              ["auto", "general"].contains(settings.subject) || SubjectCatalog.subjects.contains(where: { $0.id == settings.subject }),
              settings.additionalSubject.isEmpty || SubjectCatalog.subjects.contains(where: { $0.id == settings.additionalSubject }) else {
            throw LectureError.message("Couldn't read this folder's vocabulary settings. Choose a subject to repair them.")
        }
        if settings != stored { try? settings.save(folder: folder) }
        return settings
    }
    func save(folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(migrated()).write(to: folder.appendingPathComponent("vocabulary.json"), options: .atomic)
    }
    func resolved(course: String) -> [String] {
        let settings = migrated()
        if settings.canonicalSubject == "general" { return [] }
        let primary = settings.canonicalSubject == "auto" ? SubjectCatalog.guess(course) : [settings.canonicalSubject]
        return Array(Set(primary + (settings.additionalSubject.isEmpty ? [] : [settings.additionalSubject]))).sorted()
    }

    private func migrated() -> Self {
        var copy = self
        copy.subject = Self.canonicalID(subject)
        let secondary = additionalSubject.isEmpty ? "" : Self.canonicalID(additionalSubject)
        copy.additionalSubject = secondary == "general" ? "" : secondary
        return copy
    }

    private static func canonicalID(_ id: String) -> String {
        switch id.lowercased() {
        case "off", "none", "general": return "general"
        case "biochemistry", "biochem": return "biology"
        case "business & economics", "business-economics": return "meetings-work"
        default: return id
        }
    }
}

struct SubjectCatalog: Sendable {
    struct Subject: Identifiable, Sendable {
        let id: String
        let name: String
        let aliases: [String]
    }
    static let subjects: [Subject] = [
        .init(id: "biology", name: "Biology", aliases: ["BIOL", "BISC", "MBB", "BIOLOGY", "BIOCHEMISTRY", "BIOCHEM", "IMMUNOLOGY", "GENETICS"]),
        .init(id: "chemistry", name: "Chemistry", aliases: ["CHEM", "CHEMISTRY"]),
        .init(id: "physics", name: "Physics", aliases: ["PHYS", "PHYSICS"]),
        .init(id: "computer-science", name: "Computer Science", aliases: ["CPSC", "CMPT", "CS", "COMPUTING"]),
        .init(id: "math-statistics", name: "Math & Statistics", aliases: ["MATH", "STAT", "STATISTICS", "MATHEMATICS"]),
        .init(id: "health-medicine", name: "Health & Medicine", aliases: ["MED", "NURS", "HSCI", "HEALTH", "HEALTHCARE", "MEDICINE", "NURSING"]),
        .init(id: "psychology", name: "Psychology", aliases: ["PSYC", "PSYCHOLOGY"]),
        .init(id: "meetings-work", name: "Meetings & Work", aliases: ["ECON", "COMM", "BUS", "BUSINESS", "ECONOMICS",
                                                                         "STANDUP", "SYNC", "MEETING", "MEETINGS", "CLIENT", "INTERVIEW", "TEAM", "REVIEW",
                                                                         "MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY", "FRIDAY", "SATURDAY", "SUNDAY",
                                                                         "MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN"])
    ]
    static func name(for id: String) -> String {
        id == "general" ? "General" : subjects.first { $0.id == id }?.name ?? "General"
    }
    static func guess(_ folderName: String) -> [String] {
        let tokens = folderName.uppercased().components(separatedBy: .letters.inverted).filter { !$0.isEmpty }
        let meetingAliases = Set(subjects.first { $0.id == "meetings-work" }?.aliases ?? [])
        let oneToOne = folderName.range(of: #"(?<![\p{L}\p{N}])1\s*:\s*1(?![\p{L}\p{N}])"#,
                                        options: .regularExpression) != nil
        if oneToOne || tokens.contains(where: meetingAliases.contains) { return ["meetings-work"] }
        let phrase = " " + tokens.joined(separator: " ") + " "
        let matches = subjects.filter { subject in
            let name = subject.name.uppercased().components(separatedBy: .letters.inverted).filter { !$0.isEmpty }.joined(separator: " ")
            return subject.aliases.contains { tokens.contains($0) } || phrase.contains(" " + name + " ")
        }.map(\.id)
        return matches.isEmpty ? ["general"] : matches
    }
    static let bundled = SubjectCatalog(directory: ProcessInfo.processInfo.environment["NOSY_VOCABULARY_DIR"].map { URL(fileURLWithPath: $0) }
        ?? Bundle.main.resourceURL!.appendingPathComponent("Vocabulary"))
    let packs: [String: [String]]
    let subjectPacks: [String: [String]]
    let memberships: [String: Set<String>]
    let core: Set<String>

    init(packs: [String: [String]], subjectPacks: [String: [String]]) {
        self.packs = packs
        self.subjectPacks = subjectPacks
        core = Set(packs["stem-core"] ?? [])
        var membership: [String: Set<String>] = [:]
        for (pack, terms) in packs where pack != "stem-core" {
            for term in terms { membership[term, default: []].insert(pack) }
        }
        memberships = membership
    }
    init(directory: URL) {
        let manifest = (try? JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: directory.appendingPathComponent("subjects.json")))) ?? [:]
        var packs: [String: [String]] = [:]
        for pack in Set(manifest.values.flatMap { $0 }) {
            packs[pack] = ((try? String(contentsOf: directory.appendingPathComponent("packs/\(pack).txt"), encoding: .utf8)) ?? "")
                .split(whereSeparator: \.isNewline).map(String.init)
        }
        self.init(packs: packs, subjectPacks: Dictionary(uniqueKeysWithValues: Self.subjects.map { ($0.id, manifest[$0.name] ?? []) }))
    }
    func eligible(subjects: [String]) -> Set<String> {
        Set(subjects.flatMap { subjectPacks[$0] ?? [] })
    }
    func terms(packs selected: Set<String>) -> [String] {
        Set(selected.flatMap { packs[$0] ?? [] }).sorted()
    }
    struct Route: Codable, Sendable {
        let selected: [String]
        let scores: [String: Double]
        let distinct: [String: Int]
    }
    // Audited rule: longest non-overlapping matches; distinct terms; fractional votes.
    func route(text: String, eligible: Set<String>) -> Route {
        struct Hit { let term: String; let range: NSRange }
        var hits: [Hit] = []
        for term in terms(packs: eligible.subtracting(["stem-core"])) where !core.contains(term) {
            let alpha = term.filter(\.isLetter), digits = term.contains(where: \.isNumber)
            guard term.filter(\.isLetterOrNumber).count > 3 || (!alpha.isEmpty && digits) else { continue }
            let exactCase = !term.contains(" ") && (digits || (!alpha.isEmpty && alpha == alpha.uppercased()))
            let components = term.components(separatedBy: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "-‐‑–"))).filter { !$0.isEmpty }
            let pattern = #"(?<![\p{L}\p{N}])"# + components.map(NSRegularExpression.escapedPattern).joined(separator: #"[\s\-‐‑–]+"#) + (exactCase ? "" : "(?:s|es)?") + #"(?![\p{L}\p{N}])"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: exactCase ? [] : [.caseInsensitive]) else { continue }
            hits += regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { Hit(term: term, range: $0.range) }
        }
        hits.sort { $0.range.length != $1.range.length ? $0.range.length > $1.range.length : ($0.range.location, $0.term) < ($1.range.location, $1.term) }
        var owned: [NSRange] = [], seen = Set<String>(), scores: [String: Double] = [:], distinct: [String: Int] = [:]
        for hit in hits {
            guard !owned.contains(where: { NSIntersectionRange($0, hit.range).length > 0 }) else { continue }
            owned.append(hit.range)
            guard seen.insert(hit.term).inserted else { continue }
            let members = memberships[hit.term] ?? []
            for pack in members.intersection(eligible) {
                scores[pack, default: 0] += 1 / Double(max(1, members.count))
                distinct[pack, default: 0] += 1
            }
        }
        let threshold = max(3, (scores.values.max() ?? 0) * 0.2)
        let selected = scores.keys.filter { scores[$0]! >= threshold && distinct[$0, default: 0] >= 3 }
            .sorted { scores[$0] == scores[$1] ? $0 < $1 : scores[$0]! > scores[$1]! }.prefix(3)
        return Route(selected: Array(selected), scores: scores, distinct: distinct)
    }
}

private extension Character {
    var isLetterOrNumber: Bool { isLetter || isNumber }
}
