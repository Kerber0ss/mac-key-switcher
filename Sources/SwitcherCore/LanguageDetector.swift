import Foundation

/// Versioned, local language evidence used by the MVP detector.
public struct LanguageResources: Sendable, Equatable {
    public let version: String
    public let knownWords: Set<String>
    /// A small high-frequency subset used for bounded typo matching.
    public let nearKnownWords: Set<String>
    public let wordRanks: [String: Int]
    public let trigrams: Set<String>

    public init(version: String, knownWords: Set<String>) {
        self.init(
            version: version,
            wordRanks: Dictionary(uniqueKeysWithValues: knownWords.map { (Self.normalize($0), 1) })
        )
    }

    public init(
        version: String,
        wordRanks: [String: Int],
        trigrams: Set<String>? = nil,
        nearKnownWords: Set<String>? = nil
    ) {
        let normalizedRanks = wordRanks.reduce(into: [:]) { result, entry in
            result[Self.normalize(entry.key)] = entry.value
        }
        let knownWords = Set(normalizedRanks.keys)
        self.version = version
        self.wordRanks = normalizedRanks
        self.knownWords = knownWords
        self.nearKnownWords = Set((nearKnownWords ?? knownWords).map(Self.normalize))
        self.trigrams = trigrams ?? Set(knownWords.flatMap(Self.trigrams(in:)))
    }

    /// A damaged or empty local resource must never enable automatic correction.
    public var isUsable: Bool { !version.isEmpty && !wordRanks.isEmpty && !trigrams.isEmpty }

    /// The signed frequency resource is parsed once from the app bundle. A missing
    /// or malformed file deliberately yields an unusable resource.
    public static let minimum: LanguageResources = {
        let appResource = Bundle.main.resourceURL?
            .appending(path: "MacKeySwitcher_SwitcherCore.bundle/v2-word-ranks.tsv")
        let url = appResource.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            ?? Bundle.module.url(forResource: "v2-word-ranks", withExtension: "tsv")
        guard let url,
        let contents = try? String(contentsOf: url, encoding: .utf8)
        else { return .init(version: "", knownWords: []) }

        var ranks: [String: Int] = [:]
        var nearKnownWords = Set<String>()
        for line in contents.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 3,
                  ["en", "ru"].contains(fields[0]),
                  let rank = Int(fields[1]), rank > 0,
                  isWord(String(fields[2]), for: String(fields[0])),
                  ranks[String(fields[2])] == nil
            else { return .init(version: "", knownWords: []) }
            let word = String(fields[2])
            ranks[word] = rank
            if rank <= 1_000 { nearKnownWords.insert(word) }
        }
        let trigrams = Set(nearKnownWords.flatMap(Self.trigrams(in:)))
        return .init(version: "2", wordRanks: ranks, trigrams: trigrams, nearKnownWords: nearKnownWords)
    }()

    fileprivate static func normalize(_ word: String) -> String {
        word.precomposedStringWithCanonicalMapping.lowercased()
    }

    fileprivate static func trigrams(in word: String) -> [String] {
        let characters = Array(word)
        guard characters.count >= 3 else { return [] }
        return (0 ... characters.count - 3).map { String(characters[$0 ... $0 + 2]) }
    }

    private static func isWord(_ word: String, for language: String) -> Bool {
        let scalars = word.unicodeScalars
        guard !scalars.isEmpty else { return false }
        return switch language {
        case "en": scalars.allSatisfy { (65 ... 90).contains($0.value) || (97 ... 122).contains($0.value) }
        case "ru": scalars.allSatisfy { (0x0400 ... 0x052F).contains($0.value) }
        default: false
        }
    }
}

public enum LanguageDecision: Sendable, Equatable {
    case correct
    case keep
    case uncertain
}

public enum LanguageDecisionReason: Sendable, Equatable {
    case candidateKnown
    case sourceKnown
    case bothKnown
    case neitherKnown
    case nonAlphabetic
    case tooShort
    case approvedShortFunctionWord
    case identical
    case technicalStructure
    case mixedAlphabets
    case suspiciousStructure
    case strongCandidateMargin
    case threeCharacterExactCandidate
    case candidateNearKnown
}

public struct LanguageScores: Sendable, Equatable {
    public let source: Int
    public let candidate: Int

    public init(source: Int, candidate: Int) {
        self.source = source
        self.candidate = candidate
    }
}

public struct LanguageDetectorOutput: Sendable, Equatable {
    public let decision: LanguageDecision
    public let scores: LanguageScores
    public let reasons: [LanguageDecisionReason]

    public init(decision: LanguageDecision, scores: LanguageScores, reasons: [LanguageDecisionReason]) {
        self.decision = decision
        self.scores = scores
        self.reasons = reasons
    }
}

/// Pure, conservative comparison of a typed word with the candidate from the paired layout.
public struct LanguageDetector: Sendable {
    /// One- and two-letter words are otherwise too ambiguous to switch automatically.
    /// These are high-frequency function words whose paired-layout spelling is explicit.
    private static let approvedShortFunctionWords: Set<String> = [
        "а", "в", "и", "к", "о", "с", "у", "я", "бы", "да", "до", "же", "за", "из", "ли", "мы", "на", "не", "ни", "но", "он", "по", "то", "ты", "вы",
        "a", "i", "am", "an", "as", "at", "be", "by", "do", "go", "he", "if", "in", "is", "it", "me", "my", "no", "of", "on", "or", "so", "to", "up", "us", "we"
    ]
    private let resources: LanguageResources

    public init(resources: LanguageResources) {
        self.resources = resources
    }

    public func decide(word: String, candidate: String) -> LanguageDetectorOutput {
        let source = LanguageResources.normalize(word)
        let alternative = LanguageResources.normalize(candidate)
        guard source != alternative else {
            return .init(decision: .keep, scores: .init(source: 100, candidate: 100), reasons: [.identical])
        }
        guard !isTechnical(source), !isTechnical(alternative) else {
            return .init(decision: .uncertain, scores: .init(source: 0, candidate: 0), reasons: [.technicalStructure])
        }
        if source.count <= 2, Self.approvedShortFunctionWords.contains(alternative) {
            return .init(
                decision: .correct,
                scores: .init(source: 0, candidate: 0),
                reasons: [.approvedShortFunctionWord]
            )
        }
        guard source.count >= 3, alternative.count >= 3 else {
            return .init(decision: .uncertain, scores: .init(source: 0, candidate: 0), reasons: [.tooShort])
        }
        guard alphabet(of: source) != .mixed, alphabet(of: alternative) != .mixed else {
            return .init(decision: .uncertain, scores: .init(source: 0, candidate: 0), reasons: [.mixedAlphabets])
        }
        guard alphabet(of: source).isSupported, alphabet(of: alternative).isSupported else {
            return .init(decision: .uncertain, scores: .init(source: 0, candidate: 0), reasons: [.suspiciousStructure])
        }

        let sourceScore = score(for: source)
        let candidateScore = score(for: alternative)
        let scores = LanguageScores(source: sourceScore, candidate: candidateScore)
        let sourceInResources = resources.wordRanks[source] != nil
        let candidateInResources = resources.wordRanks[alternative] != nil
        let sourceKnown = sourceInResources
        let candidateKnown = candidateInResources
        if sourceKnown, !candidateKnown {
            return .init(decision: .keep, scores: scores, reasons: [.sourceKnown])
        } else if sourceKnown {
            return .init(decision: .uncertain, scores: scores, reasons: [.bothKnown])
        } else if !candidateKnown {
            if alternative.count >= 4, isOneTypoFromKnownWord(alternative) {
                return .init(decision: .correct, scores: scores, reasons: [.candidateNearKnown])
            }
            return .init(decision: .uncertain, scores: scores, reasons: [.neitherKnown])
        } else if candidateScore - sourceScore < 60 {
            return .init(decision: .uncertain, scores: scores, reasons: [.strongCandidateMargin])
        } else if source.count == 3 {
            return .init(
                decision: .correct,
                scores: scores,
                reasons: [.candidateKnown, .threeCharacterExactCandidate, .strongCandidateMargin]
            )
        } else {
            return .init(decision: .correct, scores: scores, reasons: [.candidateKnown])
        }
    }

    private func score(for word: String) -> Int {
        guard let rank = resources.wordRanks[word] else { return 0 }
        let rankScore = 79 - min(rank - 1, 19)
        let trigrams = LanguageResources.trigrams(in: word)
        let trigramScore = trigrams.isEmpty ? 0 : 16 * trigrams.filter(resources.trigrams.contains).count / trigrams.count
        return rankScore + trigramScore + 5
    }

    private func isTechnical(_ word: String) -> Bool {
        TechnicalToken.containsTechnical(word)
    }

    private func isOneTypoFromKnownWord(_ word: String) -> Bool {
        resources.nearKnownWords.contains { editDistance(from: word, to: $0) == 1 }
    }

    private func editDistance(from lhs: String, to rhs: String) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)
        guard abs(left.count - right.count) <= 1 else { return 2 }
        var previous = Array(0 ... right.count)
        for (leftIndex, leftCharacter) in left.enumerated() {
            var current = [leftIndex + 1]
            for (rightIndex, rightCharacter) in right.enumerated() {
                current.append(min(
                    previous[rightIndex + 1] + 1,
                    current[rightIndex] + 1,
                    previous[rightIndex] + (leftCharacter == rightCharacter ? 0 : 1)
                ))
            }
            previous = current
        }
        return previous[right.count]
    }

    private func alphabet(of word: String) -> Alphabet {
        let alphabets = Set(word.unicodeScalars.map { scalar -> Alphabet in
            switch scalar.value {
            case 65 ... 90, 97 ... 122: .latin
            case 0x0400 ... 0x052F: .cyrillic
            default: .other
            }
        })
        return alphabets.count == 1 ? alphabets.first! : alphabets.contains(.latin) && alphabets.contains(.cyrillic) ? .mixed : .other
    }
}

private enum Alphabet: Hashable {
    case latin
    case cyrillic
    case mixed
    case other

    var isSupported: Bool { self == .latin || self == .cyrillic }
}
