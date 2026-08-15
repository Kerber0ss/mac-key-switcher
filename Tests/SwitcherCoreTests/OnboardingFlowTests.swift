import XCTest
@testable import SwitcherCore

final class OnboardingFlowTests: XCTestCase {
    private func flow(
        layoutPairSelected: Bool = false,
        privacyAcknowledged: Bool = false,
        listenEvents: Bool = false,
        accessibility: Bool = false
    ) -> OnboardingFlow {
        OnboardingFlow(
            layoutPairSelected: layoutPairSelected,
            privacyAcknowledged: privacyAcknowledged,
            permissions: PermissionSnapshot(
                listenEventsGranted: listenEvents,
                accessibilityGranted: accessibility
            )
        )
    }

    func testStartsByAskingForALayoutPair() {
        let onboarding = flow()

        XCTAssertEqual(onboarding.step, .chooseLayouts)
        XCTAssertNil(onboarding.pendingPermission)
        XCTAssertFalse(onboarding.isComplete)
        XCTAssertEqual(onboarding.stepNumber, 1)
    }

    func testSelectingLayoutsMovesToPrivacyExplanation() {
        let onboarding = flow(layoutPairSelected: true)

        XCTAssertEqual(onboarding.step, .privacy)
        XCTAssertNil(onboarding.pendingPermission)
        XCTAssertEqual(onboarding.stepNumber, 2)
    }

    func testAcknowledgingPrivacyMovesToTheFirstPermission() {
        let onboarding = flow(layoutPairSelected: true, privacyAcknowledged: true)

        XCTAssertEqual(onboarding.step, .grantListenEvents)
        XCTAssertEqual(onboarding.pendingPermission, .listenEvents)
    }

    func testPermissionsAreRequestedOneAtATimeListenEventsBeforeAccessibility() {
        let afterListenEvents = flow(
            layoutPairSelected: true,
            privacyAcknowledged: true,
            listenEvents: true
        )

        XCTAssertEqual(afterListenEvents.step, .grantAccessibility)
        XCTAssertEqual(afterListenEvents.pendingPermission, .accessibility)
    }

    func testAccessibilityBeforeListenEventsStillAsksForListenEventsFirst() {
        // Even if accessibility was somehow granted first, the flow keeps the
        // fixed order and asks for the still-missing monitoring permission.
        let onboarding = flow(
            layoutPairSelected: true,
            privacyAcknowledged: true,
            accessibility: true
        )

        XCTAssertEqual(onboarding.step, .grantListenEvents)
        XCTAssertEqual(onboarding.pendingPermission, .listenEvents)
    }

    func testFlowCompletesWhenBothPermissionsAreGranted() {
        let onboarding = flow(
            layoutPairSelected: true,
            privacyAcknowledged: true,
            listenEvents: true,
            accessibility: true
        )

        XCTAssertEqual(onboarding.step, .done)
        XCTAssertNil(onboarding.pendingPermission)
        XCTAssertTrue(onboarding.isComplete)
    }

    func testProgressCountsFourStagesBeforeDone() {
        XCTAssertEqual(flow().totalSteps, 4)
        XCTAssertEqual(flow().stepNumber, 1)
        XCTAssertEqual(flow(layoutPairSelected: true, privacyAcknowledged: true).stepNumber, 3)
        XCTAssertEqual(
            flow(layoutPairSelected: true, privacyAcknowledged: true, listenEvents: true).stepNumber,
            4
        )
    }
}
