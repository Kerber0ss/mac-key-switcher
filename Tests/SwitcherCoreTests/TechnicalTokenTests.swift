import XCTest
@testable import SwitcherCore

/// The reducer and the language detector must share one definition of a
/// "technical" character/token. These tests pin the single source of truth
/// (`TechnicalToken`) and assert both consumers agree on the boundary tokens
/// `user_name`, `a/b`, and `x=1`.
final class TechnicalTokenTests: XCTestCase {
    private let english = KeyboardLayout(id: "english", name: "English")
    private let russian = KeyboardLayout(id: "russian", name: "Russian")

    // MARK: - The shared predicate

    func testStructuralCharactersAndDigitsAreTechnical() {
        for character in "_@/\\=?&0123456789" {
            XCTAssertTrue(TechnicalToken.isTechnical(character), "\(character) must be technical")
        }
    }

    func testLettersAndConnectorsAndSpaceAreNotTechnical() {
        for character in "abcяю-'’ ." {
            XCTAssertFalse(TechnicalToken.isTechnical(character), "\(character) must not be technical")
        }
    }

    func testContainsTechnicalMatchesTheBoundaryTokens() {
        XCTAssertTrue(TechnicalToken.containsTechnical("user_name"))
        XCTAssertTrue(TechnicalToken.containsTechnical("a/b"))
        XCTAssertTrue(TechnicalToken.containsTechnical("x=1"))
        XCTAssertFalse(TechnicalToken.containsTechnical("hello"))
        XCTAssertFalse(TechnicalToken.containsTechnical("привет"))
    }

    // MARK: - The detector uses the shared predicate

    func testDetectorTreatsBoundaryTokensAsTechnicalStructure() {
        let detector = LanguageDetector(resources: .minimum)
        // Distinct candidate so the earlier `.identical` short-circuit does not
        // fire; every one of these must be refused as technical structure.
        let cases = [
            ("user_name", "ызук_туьу"),
            ("a/b", "ф/и"),
            ("x=1", "ч=1"),
            ("http://a", "рпуз://ф"),
            ("k=v&x=y", "л=м&ч=н"),
        ]
        for (word, candidate) in cases {
            let output = detector.decide(word: word, candidate: candidate)
            XCTAssertEqual(output.decision, .uncertain, "\(word) must not be corrected")
            XCTAssertEqual(output.reasons, [.technicalStructure], "\(word) must be flagged technical")
        }
    }

    // MARK: - The reducer uses the shared predicate

    func testReducerMarksBoundaryTokensAsTechnical() {
        assertReducerToken(for: "user_name", isTechnical: true)
        assertReducerToken(for: "a/b", isTechnical: true)
        assertReducerToken(for: "x=1", isTechnical: true)
    }

    func testReducerMarksPlainWordsAsNonTechnical() {
        assertReducerToken(for: "hello", isTechnical: false)
    }

    // MARK: - Helpers

    /// Types `text` followed by a space and asserts the completed token's
    /// `isTechnical` flag, i.e. the reducer's view of technical structure.
    private func assertReducerToken(
        for text: String,
        isTechnical expected: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var reducer = InputSessionReducer(translate: { _, stroke in
            // Provide a single-character candidate for every stroke so the token
            // is well-formed; the exact glyph is irrelevant to the technical flag.
            String(Array("abcdefghijklmnopqrstuvwxyz")[Int(stroke.keyCode) % 26])
        })
        let environment = environment()
        for (index, character) in text.enumerated() {
            reducer.reduce(
                .text(.init(keyCode: UInt16(index)), output: String(character)),
                in: environment
            )
        }
        let completed = reducer.reduce(.text(.init(keyCode: 200), output: " "), in: environment)
        guard case let .lastCompleted(token) = completed.state else {
            XCTFail("expected a completed token for \(text)", file: file, line: line)
            return
        }
        XCTAssertEqual(token.isTechnical, expected, "technical flag for \(text)", file: file, line: line)
    }

    private func environment() -> InputSessionEnvironment {
        .init(
            configuration: .init(revision: 1, isEnabled: true),
            focus: .init(applicationID: "TextEdit", elementID: "body", isSupported: true),
            policy: .init(allowsTracking: true),
            layouts: .init(
                pair: .init(english: english, russian: russian),
                availableLayoutIDs: [english.id, russian.id],
                activeLayoutID: english.id
            )
        )
    }
}
