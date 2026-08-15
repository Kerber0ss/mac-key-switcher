import XCTest
@testable import SwitcherCore

final class PermissionOnboardingTests: XCTestCase {
    func testSnapshotNamesTheFirstMissingPermissionForTheMenu() {
        let snapshot = PermissionSnapshot(
            listenEventsGranted: false,
            accessibilityGranted: true
        )

        XCTAssertEqual(snapshot.missingPermissions, [.listenEvents])
        XCTAssertEqual(snapshot.menuTitle, "Требуется разрешение: Мониторинг ввода")
        XCTAssertEqual(snapshot.missingPermissionsMessage, "Мониторинг ввода")
        XCTAssertFalse(snapshot.canMonitor)
    }

    func testAccessibilityAlsoGrantsTheRightToPostReplacementEvents() {
        let snapshot = PermissionSnapshot(
            listenEventsGranted: true,
            accessibilityGranted: true
        )

        XCTAssertTrue(snapshot.canMonitor)
        XCTAssertEqual(snapshot.menuTitle, "Разрешения выданы")
    }

    func testMissingPermissionsNeverAskForASecondAccessibilityToggle() {
        let snapshot = PermissionSnapshot(
            listenEventsGranted: true,
            accessibilityGranted: false
        )

        XCTAssertEqual(snapshot.missingPermissions, [.accessibility])
        XCTAssertEqual(snapshot.missingPermissionsMessage, "Универсальный доступ")
    }
}
