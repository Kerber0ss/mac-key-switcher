import Foundation
import XCTest
@testable import SwitcherCore

final class AutomationSettingsStoreTests: XCTestCase {
    func testDefaultsToEnabledAndPersistsAutomationAndNormalizedExceptions() {
        let defaults = makeDefaults()
        let store = AutomationSettingsStore(defaults: defaults)

        XCTAssertEqual(store.snapshot, .init(revision: 0, isAutomationEnabled: true, wordExceptions: []))

        store.apply(.setAutomationEnabled(false))
        store.apply(.addWordException("ПРИВЕ\u{301}Т"))
        store.apply(.addWordException("приве\u{0301}т"))

        let reloaded = AutomationSettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.snapshot.isAutomationEnabled, false)
        XCTAssertEqual(reloaded.snapshot.wordExceptions, ["приве\u{301}т"])
        XCTAssertTrue(reloaded.snapshot.excludes("ПРИВЕ\u{0301}Т"))
    }

    func testEveryEffectiveChangeIncrementsRevisionAndRemovingUsesNormalizedSpelling() {
        let store = AutomationSettingsStore(defaults: makeDefaults())

        XCTAssertEqual(store.apply(.addWordException("Ghbdtn")).revision, 1)
        XCTAssertEqual(store.apply(.addWordException("GHBDTN")).revision, 1)
        XCTAssertEqual(store.apply(.setAutomationEnabled(false)).revision, 2)
        XCTAssertEqual(store.apply(.removeWordException("ghbdtn")).revision, 3)
        XCTAssertEqual(store.snapshot.wordExceptions, [])
    }

    func testConfigurationKeepsManualTrackingAvailableWhenAutomationIsOff() {
        let settings = AutomationSettings(revision: 3, isAutomationEnabled: false, wordExceptions: ["ghbdtn"])
        let configuration = InputSessionConfiguration(settings: settings)

        XCTAssertFalse(configuration.isAutomationEnabled)
        XCTAssertTrue(configuration.excludesFromAutomation("GHBDTN"))
    }

    func testManualShortcutPersistsAndAdvancesTheRevision() {
        let defaults = makeDefaults()
        let store = AutomationSettingsStore(defaults: defaults)
        let shortcut: ManualConversionShortcut = .key(keyCode: 101, modifierFlags: 1 << 20)

        XCTAssertEqual(store.apply(.setManualConversionShortcut(shortcut)).revision, 1)
        XCTAssertEqual(store.snapshot.manualConversionShortcut, shortcut)
        XCTAssertEqual(AutomationSettingsStore(defaults: defaults).snapshot.manualConversionShortcut, shortcut)
        XCTAssertEqual(store.apply(.setManualConversionShortcut(shortcut)).revision, 1)
    }

    private func makeDefaults() -> UserDefaults {
        let name = "AutomationSettingsStoreTests.\(UUID().uuidString)"
        return UserDefaults(suiteName: name)!
    }
}
