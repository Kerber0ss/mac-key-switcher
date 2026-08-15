import ApplicationServices
import CoreFoundation
import XCTest
@testable import SwitcherCore

/// Covers task 0.4: malformed / unexpected AX attribute values must fail closed
/// (return `nil`) instead of force-casting and crashing the process.
final class AXValueCastingTests: XCTestCase {
    // MARK: - Malformed data must not trap

    func testUIElementRejectsWrongCFType() {
        // A plain CFString is the kind of malformed value that `value as! AXUIElement`
        // would have trapped on.
        let malformed = "not an element" as CFString
        XCTAssertNil(AXValueCasting.uiElement(from: malformed))
    }

    func testUIElementRejectsAXValue() {
        // An AXValue is a valid CF type but the wrong AX type for an element.
        var range = CFRange(location: 0, length: 0)
        let axValue = AXValueCreate(.cfRange, &range)
        XCTAssertNil(AXValueCasting.uiElement(from: axValue))
    }

    func testAXValueRejectsWrongCFType() {
        let malformed = 42 as CFNumber
        XCTAssertNil(AXValueCasting.axValue(from: malformed))
    }

    func testCastsRejectNil() {
        XCTAssertNil(AXValueCasting.uiElement(from: nil))
        XCTAssertNil(AXValueCasting.axValue(from: nil))
    }

    // MARK: - Well-formed data must pass through

    func testAXValueAcceptsRealAXValueAndPreservesPayload() {
        var range = CFRange(location: 3, length: 5)
        guard let wrapped = AXValueCreate(.cfRange, &range) else {
            return XCTFail("Failed to build an AXValue for the test")
        }
        guard let casted = AXValueCasting.axValue(from: wrapped) else {
            return XCTFail("A genuine AXValue must not be rejected")
        }
        var readBack = CFRange()
        XCTAssertTrue(AXValueGetValue(casted, .cfRange, &readBack))
        XCTAssertEqual(readBack.location, 3)
        XCTAssertEqual(readBack.length, 5)
    }

    func testUIElementAcceptsRealAXUIElement() {
        // The system-wide element is a genuine AXUIElement and always creatable.
        let systemWide: CFTypeRef = AXUIElementCreateSystemWide()
        XCTAssertNotNil(AXValueCasting.uiElement(from: systemWide))
    }
}
