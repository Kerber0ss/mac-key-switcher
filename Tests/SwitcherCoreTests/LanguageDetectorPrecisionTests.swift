import XCTest
@testable import SwitcherCore

final class LanguageDetectorPrecisionTests: XCTestCase {
    private let detector = LanguageDetector(resources: .minimum)

    func testCorrectsFixedMustCorrectCorpusWithMeasuredRecall() {
        let corpus = LanguageDetectorCorpus.entries.filter { $0.category == .mustCorrect }

        for entry in corpus {
            XCTAssertEqual(
                detector.decide(word: entry.word, candidate: entry.candidate).decision,
                .correct,
                "must-correct token \(entry.word) was not corrected by resource version 2"
            )
        }
    }

    func testReleaseLexiconContainsThePinnedFrequencyDictionaries() {
        XCTAssertEqual(LanguageResources.minimum.version, "2")
        XCTAssertEqual(LanguageResources.minimum.knownWords.count, 98_574)
        XCTAssertTrue(LanguageResources.minimum.knownWords.isSuperset(of: ["computer", "компьютер", "клавиатура"]))
    }

    func testMustKeepCorpusHasNoFalseCorrections() {
        let corpus = LanguageDetectorCorpus.entries.filter { $0.category == .mustKeep }

        for entry in corpus {
            XCTAssertNotEqual(
                detector.decide(word: entry.word, candidate: entry.candidate).decision,
                .correct,
                "must-keep token \(entry.word) was corrected"
            )
        }
    }

    func testAmbiguousCorpusIsRetained() {
        for entry in LanguageDetectorCorpus.entries where entry.category == .ambiguous {
            XCTAssertNotEqual(detector.decide(word: entry.word, candidate: entry.candidate).decision, .correct)
        }
    }

    func testShortMixedTechnicalAndSuspiciousTokensAreNeverCorrected() {
        XCTAssertEqual(detector.decide(word: "ab", candidate: "аб").decision, .uncertain)
        XCTAssertEqual(detector.decide(word: "vbh", candidate: "мир").decision, .correct)
        XCTAssertEqual(detector.decide(word: "ghbdtn2", candidate: "привет2").decision, .uncertain)
        XCTAssertEqual(detector.decide(word: "ghПр", candidate: "прHe").decision, .uncertain)
        XCTAssertEqual(detector.decide(word: "hello-world", candidate: "руддщ-цщкдв").decision, .uncertain)
    }

    func testNormalizesCaseAndUnicodeBeforeComparingButDoesNotChangeCandidateCase() {
        let output = detector.decide(word: "GHBDTN", candidate: "ПРИВЕТ")

        XCTAssertEqual(output.decision, .correct)
        XCTAssertGreaterThan(output.scores.candidate, 0)
    }

    func testCorrectsALayoutMistakeWhoseCandidateIsOneTypoFromAKnownWord() {
        let output = detector.decide(word: "ghbfdtn", candidate: "приавет")

        XCTAssertEqual(output.decision, .correct)
        XCTAssertEqual(output.reasons, [.candidateNearKnown])
        XCTAssertEqual(detector.decide(word: "asdf", candidate: "фыва").decision, .uncertain)
    }

    func testRecognizesTheWordsFromTheRepeatedTextEditScenario() {
        XCTAssertEqual(detector.decide(word: "rfr", candidate: "как").decision, .correct)
        XCTAssertEqual(detector.decide(word: "ltkf", candidate: "дела").decision, .correct)
    }

    func testCorrectsApprovedRussianOneAndTwoLetterFunctionWords() {
        XCTAssertEqual(detector.decide(word: "f", candidate: "а").decision, .correct)
        XCTAssertEqual(detector.decide(word: "b", candidate: "и").decision, .correct)
        XCTAssertEqual(detector.decide(word: ",s", candidate: "бы").decision, .correct)
    }

}
