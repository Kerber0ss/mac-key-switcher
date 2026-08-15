import XCTest
@testable import SwitcherCore

final class ApplicationStateTests: XCTestCase {
    func testInitialStateExplainsThatConfigurationIsRequired() {
        XCTAssertEqual(ApplicationState.initial, .missingPermissions)
        XCTAssertEqual(ApplicationState.initial.menuTitle, "Требуется настройка")
    }

    func testMenuChoosesOneConcreteRecoveryState() {
        XCTAssertEqual(ApplicationState.resolve(permissionsGranted: false, layoutPairAvailable: true, languageResourcesAvailable: true, eventMonitorIsOperational: true, isAutomationEnabled: true), .missingPermissions)
        XCTAssertEqual(ApplicationState.resolve(permissionsGranted: true, layoutPairAvailable: false, languageResourcesAvailable: true, eventMonitorIsOperational: true, isAutomationEnabled: true), .layoutPairUnavailable)
        XCTAssertEqual(ApplicationState.resolve(permissionsGranted: true, layoutPairAvailable: true, languageResourcesAvailable: false, eventMonitorIsOperational: true, isAutomationEnabled: true), .languageResourcesFailed)
        XCTAssertEqual(ApplicationState.resolve(permissionsGranted: true, layoutPairAvailable: true, languageResourcesAvailable: true, eventMonitorIsOperational: false, isAutomationEnabled: true), .eventMonitorFailed)
        XCTAssertEqual(ApplicationState.languageResourcesFailed.primaryActionTitle, "Перезапустить приложение")
        XCTAssertEqual(ApplicationState.eventMonitorFailed.primaryActionTitle, "Повторить мониторинг")
    }

    func testMenuDistinguishesReadyAutomationAndOffersItsNextAction() {
        XCTAssertEqual(ApplicationState.ready.menuTitle, "Готово")
        XCTAssertEqual(ApplicationState.ready.primaryActionTitle, "Выключить автоматику")
        XCTAssertEqual(ApplicationState.automationOff.menuTitle, "Автоматика выключена")
        XCTAssertEqual(ApplicationState.automationOff.primaryActionTitle, "Включить автоматику")
    }

    func testLayoutSelectionFailureHasItsOwnRecoveryState() {
        XCTAssertEqual(
            ApplicationState.resolve(
                permissionsGranted: true,
                layoutPairAvailable: true,
                languageResourcesAvailable: true,
                eventMonitorIsOperational: true,
                automaticCorrectionIsAvailable: false,
                isAutomationEnabled: true
            ),
            .automaticCorrectionFailed
        )
        XCTAssertEqual(ApplicationState.automaticCorrectionFailed.primaryActionTitle, "Перезапустить приложение")
    }

    func testMenuActionDoesNotTreatPermissionSetupAsAnAutomationToggle() {
        XCTAssertEqual(ApplicationState.missingPermissions.primaryActionTitle, "Выдать разрешения…")
        XCTAssertEqual(ApplicationState.missingPermissions.menuAction, .openPermissions)
        XCTAssertEqual(ApplicationState.ready.menuAction, .toggleAutomation)
        XCTAssertEqual(ApplicationState.automationOff.menuAction, .toggleAutomation)
    }

    func testEmptyLanguageResourcesAreNotUsableForAutomation() {
        XCTAssertFalse(LanguageResources(version: "", knownWords: []).isUsable)
        XCTAssertTrue(LanguageResources.minimum.isUsable)
    }
}
