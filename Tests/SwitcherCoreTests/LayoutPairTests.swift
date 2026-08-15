import XCTest
@testable import SwitcherCore

final class LayoutPairTests: XCTestCase {
    private let abc = KeyboardLayout(id: "com.apple.keylayout.ABC", name: "ABC")
    private let russian = KeyboardLayout(id: "com.apple.keylayout.Russian", name: "Russian")

    func testSelectsTwoDifferentAvailableLayouts() throws {
        let pair = try LayoutPair.select(
            englishID: abc.id,
            russianID: russian.id,
            from: [abc, russian]
        ).get()

        XCTAssertEqual(pair.english, abc)
        XCTAssertEqual(pair.russian, russian)
    }

    func testRejectsIncompleteAndDuplicateSelections() {
        XCTAssertThrowsError(try LayoutPair.select(englishID: nil, russianID: russian.id, from: [abc, russian]).get())
        XCTAssertThrowsError(try LayoutPair.select(englishID: abc.id, russianID: abc.id, from: [abc, russian]).get())
    }

    func testReportsUnavailablePairWhenAChosenLayoutIsNoLongerEnabled() throws {
        let pair = try LayoutPair.select(englishID: abc.id, russianID: russian.id, from: [abc, russian]).get()

        XCTAssertEqual(pair.availability(in: [abc]), .unavailable)
    }

    func testConvertsKnownABCRussianLettersInBothDirectionsWithShiftAndCapsLock() throws {
        let pair = try LayoutPair.select(englishID: abc.id, russianID: russian.id, from: [abc, russian]).get()
        let converter = LayoutPairConverter(pair: pair) { layout, stroke in
            switch (layout.id, stroke.keyCode, stroke.modifiers) {
            case ("com.apple.keylayout.ABC", 5, []): "g"
            case ("com.apple.keylayout.Russian", 5, []): "п"
            case ("com.apple.keylayout.ABC", 4, [.shift]): "h"
            case ("com.apple.keylayout.Russian", 4, [.shift]): "Р"
            case ("com.apple.keylayout.ABC", 4, [.capsLock]): "H"
            case ("com.apple.keylayout.Russian", 4, [.capsLock]): "Р"
            default: nil
            }
        }

        XCTAssertEqual(converter.candidate(for: KeyStroke(keyCode: 5), activeLayoutID: abc.id), "п")
        XCTAssertEqual(converter.candidate(for: KeyStroke(keyCode: 5), activeLayoutID: russian.id), "g")
        XCTAssertEqual(converter.candidate(for: KeyStroke(keyCode: 4, modifiers: [.shift]), activeLayoutID: abc.id), "Р")
        XCTAssertEqual(converter.candidate(for: KeyStroke(keyCode: 4, modifiers: [.capsLock]), activeLayoutID: russian.id), "H")
    }

    func testDoesNothingForAnActiveThirdInputSource() throws {
        let pair = try LayoutPair.select(englishID: abc.id, russianID: russian.id, from: [abc, russian]).get()
        let converter = LayoutPairConverter(pair: pair) { _, _ in "x" }

        XCTAssertNil(converter.candidate(for: KeyStroke(keyCode: 5), activeLayoutID: "com.apple.keylayout.French"))
    }
}
