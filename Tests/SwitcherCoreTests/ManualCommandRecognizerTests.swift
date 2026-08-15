import XCTest
@testable import SwitcherCore

/// Narrow tests for the single command-recognition layer introduced in Phase 2.
///
/// These would not compile against the old code (recognition was duplicated
/// inside each coordinator as a private state machine) and lock down the exact
/// Double Shift boundary conditions.
final class ManualCommandRecognizerTests: XCTestCase {
    func testTwoFullPressesOfTheSameShiftInsideTheWindowFireOnce() {
        var recognizer = ManualCommandRecognizer()

        XCTAssertFalse(recognizer.consume(.shiftDown(.left, milliseconds: 0)))
        XCTAssertFalse(recognizer.consume(.shiftUp(.left, milliseconds: 30)))
        XCTAssertFalse(recognizer.consume(.shiftDown(.left, milliseconds: 100)))
        XCTAssertTrue(recognizer.consume(.shiftUp(.left, milliseconds: 130)))
    }

    func testRightShiftDoubleTapAlsoFires() {
        var recognizer = ManualCommandRecognizer()

        XCTAssertFalse(recognizer.consume(.shiftDown(.right, milliseconds: 0)))
        XCTAssertFalse(recognizer.consume(.shiftUp(.right, milliseconds: 20)))
        XCTAssertFalse(recognizer.consume(.shiftDown(.right, milliseconds: 40)))
        XCTAssertTrue(recognizer.consume(.shiftUp(.right, milliseconds: 60)))
    }

    func testTwoDifferentShiftKeysNeverFormACommand() {
        var recognizer = ManualCommandRecognizer()

        // Left down/up, then right down/up: two different physical keys.
        XCTAssertFalse(recognizer.consume(.shiftDown(.left, milliseconds: 0)))
        XCTAssertFalse(recognizer.consume(.shiftUp(.left, milliseconds: 30)))
        XCTAssertFalse(recognizer.consume(.shiftDown(.right, milliseconds: 100)))
        XCTAssertFalse(recognizer.consume(.shiftUp(.right, milliseconds: 130)))
    }

    func testSecondPressExactlyAtTheWindowBoundaryStillFires() {
        var recognizer = ManualCommandRecognizer()
        let window = ManualCommandRecognizer.doubleShiftWindowMilliseconds

        XCTAssertFalse(recognizer.consume(.shiftDown(.left, milliseconds: 0)))
        XCTAssertFalse(recognizer.consume(.shiftUp(.left, milliseconds: 0)))
        // Second press happens exactly `window` ms after the first release.
        XCTAssertFalse(recognizer.consume(.shiftDown(.left, milliseconds: window)))
        XCTAssertTrue(recognizer.consume(.shiftUp(.left, milliseconds: window + 5)))
    }

    func testSecondPressPastTheWindowDoesNotFire() {
        var recognizer = ManualCommandRecognizer()
        let tooLate = ManualCommandRecognizer.doubleShiftWindowMilliseconds + 1

        XCTAssertFalse(recognizer.consume(.shiftDown(.left, milliseconds: 0)))
        XCTAssertFalse(recognizer.consume(.shiftUp(.left, milliseconds: 0)))
        XCTAssertFalse(recognizer.consume(.shiftDown(.left, milliseconds: tooLate)))
        XCTAssertFalse(recognizer.consume(.shiftUp(.left, milliseconds: tooLate + 5)))
    }

    func testAKeyPressedBetweenTheTwoTapsCancelsTheSequence() {
        var recognizer = ManualCommandRecognizer()

        XCTAssertFalse(recognizer.consume(.shiftDown(.left, milliseconds: 0)))
        XCTAssertFalse(recognizer.consume(.shiftUp(.left, milliseconds: 30)))
        // An intervening character breaks the pending Double Shift.
        XCTAssertFalse(recognizer.consume(.text(.init(keyCode: 9), output: "a")))
        XCTAssertFalse(recognizer.consume(.shiftDown(.left, milliseconds: 100)))
        XCTAssertFalse(recognizer.consume(.shiftUp(.left, milliseconds: 130)))
    }

    func testHoldingShiftDownTwiceWithoutAReleaseNeverFires() {
        var recognizer = ManualCommandRecognizer()

        XCTAssertFalse(recognizer.consume(.shiftDown(.left, milliseconds: 0)))
        XCTAssertFalse(recognizer.consume(.shiftDown(.left, milliseconds: 10)))
        XCTAssertFalse(recognizer.consume(.shiftUp(.left, milliseconds: 20)))
    }

    func testAManualCommandEventFiresImmediately() {
        var recognizer = ManualCommandRecognizer()

        XCTAssertTrue(recognizer.consume(.manualCommand))
    }

    func testManualCommandResetsAPartiallyObservedDoubleShift() {
        var recognizer = ManualCommandRecognizer()

        XCTAssertFalse(recognizer.consume(.shiftDown(.left, milliseconds: 0)))
        // A custom shortcut fires immediately and clears the half-formed tap.
        XCTAssertTrue(recognizer.consume(.manualCommand))
        // The stale first tap must not combine with later taps: a full Double
        // Shift now requires two fresh press/release pairs to fire again.
        XCTAssertFalse(recognizer.consume(.shiftUp(.left, milliseconds: 30)))
        XCTAssertFalse(recognizer.consume(.shiftDown(.left, milliseconds: 60)))
        XCTAssertFalse(recognizer.consume(.shiftUp(.left, milliseconds: 90)))
        XCTAssertFalse(recognizer.consume(.shiftDown(.left, milliseconds: 120)))
        XCTAssertTrue(recognizer.consume(.shiftUp(.left, milliseconds: 150)))
    }

    func testResetDropsAPartiallyObservedSequence() {
        var recognizer = ManualCommandRecognizer()

        XCTAssertFalse(recognizer.consume(.shiftDown(.left, milliseconds: 0)))
        XCTAssertFalse(recognizer.consume(.shiftUp(.left, milliseconds: 30)))
        recognizer.reset()
        // After a reset the next down/up is only a first tap, not a completion.
        XCTAssertFalse(recognizer.consume(.shiftDown(.left, milliseconds: 60)))
        XCTAssertFalse(recognizer.consume(.shiftUp(.left, milliseconds: 90)))
    }

    func testCanFireRepeatedlyForConsecutiveCommands() {
        var recognizer = ManualCommandRecognizer()

        XCTAssertFalse(recognizer.consume(.shiftDown(.left, milliseconds: 0)))
        XCTAssertFalse(recognizer.consume(.shiftUp(.left, milliseconds: 30)))
        XCTAssertFalse(recognizer.consume(.shiftDown(.left, milliseconds: 100)))
        XCTAssertTrue(recognizer.consume(.shiftUp(.left, milliseconds: 130)))

        // A second Double Shift right after the first also fires.
        XCTAssertFalse(recognizer.consume(.shiftDown(.left, milliseconds: 200)))
        XCTAssertFalse(recognizer.consume(.shiftUp(.left, milliseconds: 230)))
        XCTAssertFalse(recognizer.consume(.shiftDown(.left, milliseconds: 300)))
        XCTAssertTrue(recognizer.consume(.shiftUp(.left, milliseconds: 330)))
    }
}
