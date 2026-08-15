import Foundation
import XCTest
@testable import SwitcherCore

final class ExcludedApplicationPolicyTests: XCTestCase {
    func testSupportedOrdinaryApplicationAllowsAutomaticAndManualConversion() {
        let permissions = ExcludedApplicationPolicy().permissions(
            for: "com.apple.TextEdit",
            context: .supported
        )

        XCTAssertTrue(permissions.allowsAutomaticCorrection)
        XCTAssertTrue(permissions.allowsManualConversion)
    }

    func testUserExcludedApplicationDeniesOnlyAutomaticCorrection() {
        let permissions = ExcludedApplicationPolicy(userExcludedBundleIDs: ["com.example.Editor"]).permissions(
            for: "com.example.Editor",
            context: .supported
        )

        XCTAssertFalse(permissions.allowsAutomaticCorrection)
        XCTAssertTrue(permissions.allowsManualConversion)
    }

    func testProtectedContextDeniesBothCapabilities() {
        let policy = ExcludedApplicationPolicy()

        let permissions = policy.permissions(for: "com.apple.TextEdit", context: .protected)

        XCTAssertFalse(permissions.allowsAutomaticCorrection)
        XCTAssertFalse(permissions.allowsManualConversion)
    }

    func testUnknownContextAllowsAnApplicationThatIsNotExcluded() {
        let permissions = ExcludedApplicationPolicy().permissions(
            for: "com.mattermost.desktop",
            context: .unknown
        )

        XCTAssertTrue(permissions.allowsAutomaticCorrection)
        XCTAssertTrue(permissions.allowsManualConversion)
    }

    func testPolicyChangeBreaksTheActiveInputSession() {
        var reducer = InputSessionReducer(translate: { _, _ in "п" })
        let common = InputSessionEnvironment(
            configuration: .init(revision: 1, isEnabled: true),
            focus: .init(applicationID: "com.example.Editor", elementID: "body", processID: 42, isSupported: true),
            policy: ExcludedApplicationPolicy(revision: 1).permissions(for: "com.example.Editor", context: .supported),
            layouts: .init(
                pair: .init(english: .init(id: "english", name: "English"), russian: .init(id: "russian", name: "Russian")),
                availableLayoutIDs: ["english", "russian"],
                activeLayoutID: "english"
            )
        )
        let excluded = InputSessionEnvironment(
            configuration: common.configuration,
            focus: common.focus,
            policy: ExcludedApplicationPolicy(userExcludedBundleIDs: ["com.example.Editor"], revision: 2)
                .permissions(for: "com.example.Editor", context: .supported),
            layouts: common.layouts
        )

        reducer.reduce(.text(.init(keyCode: 1), output: "g"), in: common)
        let result = reducer.reduce(.text(.init(keyCode: 2), output: "h"), in: excluded)

        XCTAssertEqual(result.commands, [.breakSession(.environmentChanged)])
        XCTAssertEqual(result.state, .idle)
    }

    func testStorePersistsConcreteBundleIDsAndRejectsProcessNames() {
        let name = "ExcludedApplicationPolicyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = ExcludedApplicationStore(defaults: defaults)

        store.add(bundleID: "Visual Studio Code")
        store.add(bundleID: "com.microsoft.VSCode")

        XCTAssertEqual(store.userExcludedBundleIDs, ["com.microsoft.VSCode"])
        XCTAssertEqual(
            ExcludedApplicationStore(defaults: defaults).userExcludedBundleIDs,
            ["com.microsoft.VSCode"]
        )
    }

    func testExcludedApplicationDoesNotScheduleAutomaticCorrectionButKeepsSafeManualConversion() {
        let policy = ExcludedApplicationPolicy(userExcludedBundleIDs: ["com.example.Editor"])
        let environment = environment(policy: policy.permissions(for: "com.example.Editor", context: .supported))
        let automaticInjector = PolicyInjector()
        let automatic = AutomaticCorrectionCoordinator(
            focusInspector: PolicyInspector(texts: []),
            textInjector: automaticInjector,
            inputSourceService: PolicyInputSource(),
            detector: .init(resources: .minimum),
            translate: candidate
        )

        for (offset, character) in "ghbdtn".enumerated() {
            automatic.receive(.text(.init(keyCode: UInt16(offset + 1)), output: String(character)), in: environment)
        }
        XCTAssertEqual(automatic.receive(.text(.init(keyCode: 50), output: " "), in: environment), .ignored)
        XCTAssertTrue(automaticInjector.operations.isEmpty)

        let manualInjector = PolicyInjector()
        let manual = ManualConversionCoordinator(
            focusInspector: PolicyInspector(texts: ["gh", "пр"]),
            textInjector: manualInjector,
            inputSourceService: PolicyInputSource(),
            translate: candidate
        )
        for (keyCode, output) in [(1, "g"), (2, "h")] {
            manual.receive(.text(.init(keyCode: UInt16(keyCode)), output: output), in: environment)
        }
        triggerDoubleShift(manual, in: environment)

        // Manual conversion stays available in a user-excluded application: the
        // exclusion policy denies only automatic correction
        // (`allowsAutomaticCorrection == false`) while keeping
        // `allowsManualConversion == true`, so an explicit Double Shift still
        // converts the tracked word.
        XCTAssertEqual(manualInjector.operations, [.backspace(2), .unicode("пр")])
    }

    private func environment(policy: InputPolicySnapshot) -> InputSessionEnvironment {
        .init(
            configuration: .init(revision: 1, isEnabled: true),
            focus: .init(applicationID: "com.example.Editor", elementID: "body", processID: 42, isSupported: true),
            policy: policy,
            layouts: .init(
                pair: .init(english: .init(id: "english", name: "English"), russian: .init(id: "russian", name: "Russian")),
                availableLayoutIDs: ["english", "russian"],
                activeLayoutID: "english"
            )
        )
    }

    private func candidate(_ layout: KeyboardLayout, _ stroke: KeyStroke) -> String? {
        guard layout.id == "russian" else { return nil }
        return [1: "п", 2: "р", 3: "и", 4: "в", 5: "е", 6: "т"][stroke.keyCode]
    }

    private func triggerDoubleShift(_ coordinator: ManualConversionCoordinator, in environment: InputSessionEnvironment) {
        coordinator.performCommand(in: environment)
    }
}

private final class PolicyInspector: FocusInspector, @unchecked Sendable {
    private var texts: [String]

    init(texts: [String]) { self.texts = texts }

    func replacementProof(beforeCursorCount: Int) -> ReplacementProof {
        guard !texts.isEmpty else { return .opaque }
        return .exact(.init(
            processID: 42, elementID: "body", role: .textArea, isProtected: false,
            selection: .init(location: beforeCursorCount, length: 0), localTextBeforeCursor: texts.removeFirst()
        ))
    }
}

private final class PolicyInjector: TextInjector, @unchecked Sendable {
    enum Operation: Equatable { case backspace(Int), unicode(String) }
    private(set) var operations: [Operation] = []
    func sendMarkedBackspaces(_ count: Int) -> Bool { operations.append(.backspace(count)); return true }
    func sendMarkedUnicode(_ text: String) -> Bool { operations.append(.unicode(text)); return true }
}

private final class PolicyInputSource: InputSourceService, @unchecked Sendable {
    func selectInputSource(id: String) -> Bool { true }
}
