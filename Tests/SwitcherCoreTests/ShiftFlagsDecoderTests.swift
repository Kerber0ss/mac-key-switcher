import XCTest
@testable import SwitcherCore

/// Covers task 0.1: the physical direction of a Shift key must come from that
/// key's own device-dependent bit, not the aggregate `.maskShift` flag.
final class ShiftFlagsDecoderTests: XCTestCase {
    // Aggregate Shift flag (kCGEventFlagMaskShift == 1 << 17). It is true while
    // *either* Shift key is held, which is exactly what made the old code wrong.
    private let maskShift: UInt64 = 1 << 17
    private let leftBit = ShiftFlagsDecoder.leftShiftMask   // NX_DEVICELSHIFTKEYMASK (0x02)
    private let rightBit = ShiftFlagsDecoder.rightShiftMask // NX_DEVICERSHIFTKEYMASK (0x04)

    func testDeviceBitsForLeftAndRightShiftAreDistinct() {
        XCTAssertEqual(leftBit, 0x02)
        XCTAssertEqual(rightBit, 0x04)
    }

    func testPressingOneShiftMarksOnlyThatSideDown() {
        let leftDown = maskShift | leftBit
        XCTAssertEqual(ShiftFlagsDecoder.direction(for: .left, flagsRawValue: leftDown), .keyDown)
        XCTAssertEqual(ShiftFlagsDecoder.direction(for: .right, flagsRawValue: leftDown), .keyUp)

        let rightDown = maskShift | rightBit
        XCTAssertEqual(ShiftFlagsDecoder.direction(for: .right, flagsRawValue: rightDown), .keyDown)
        XCTAssertEqual(ShiftFlagsDecoder.direction(for: .left, flagsRawValue: rightDown), .keyUp)
    }

    /// The exact case the old `.maskShift`-based code mis-read: while both Shift
    /// keys are held, releasing the left one still leaves `.maskShift` set (the
    /// right is down), yet the left key's own bit is cleared. The event must be a
    /// left `.keyUp`, not a `.keyDown`.
    func testReleasingLeftWhileRightHeldIsAKeyUpEvenThoughMaskShiftStaysSet() {
        // Sequence: press left → press right → release left → release right.
        let leftDown = maskShift | leftBit
        let bothDown = maskShift | leftBit | rightBit
        let leftReleasedRightHeld = maskShift | rightBit // .maskShift still set!
        let allReleased: UInt64 = 0

        XCTAssertEqual(ShiftFlagsDecoder.direction(for: .left, flagsRawValue: leftDown), .keyDown)
        XCTAssertEqual(ShiftFlagsDecoder.direction(for: .right, flagsRawValue: bothDown), .keyDown)
        // Old code: flags.contains(.maskShift) == true → wrongly .keyDown here.
        XCTAssertEqual(ShiftFlagsDecoder.direction(for: .left, flagsRawValue: leftReleasedRightHeld), .keyUp)
        XCTAssertEqual(ShiftFlagsDecoder.direction(for: .right, flagsRawValue: allReleased), .keyUp)
    }

    func testIsPressedReadsExactlyTheRequestedSide() {
        let bothDown = maskShift | leftBit | rightBit
        XCTAssertTrue(ShiftFlagsDecoder.isPressed(.left, flagsRawValue: bothDown))
        XCTAssertTrue(ShiftFlagsDecoder.isPressed(.right, flagsRawValue: bothDown))

        // A non-Shift modifier (e.g. Command) must never look like a Shift press.
        let commandOnly: UInt64 = 1 << 20
        XCTAssertFalse(ShiftFlagsDecoder.isPressed(.left, flagsRawValue: commandOnly))
        XCTAssertFalse(ShiftFlagsDecoder.isPressed(.right, flagsRawValue: commandOnly))
    }
}
