import XCTest
@testable import SwitcherCore

/// Tests for the single dispatch layer introduced in Phase 2.1.
///
/// The central guarantee: a physical Double Shift is recognized exactly once
/// and applied by exactly one coordinator.  Previously both coordinators ran
/// their own recognizer and the system runtime had to defensively suppress
/// manual conversion after automatic reversal — a desynchronization source.
final class ConversionRuntimeTests: XCTestCase {
    /// After automatic correction reverses its own replacement, manual
    /// conversion must NOT re-apply its stale copy of the same word over the
    /// restored text.
    func testAfterAutomaticCancellationManualDoesNotApplyAStaleCopy() {
        let autoFocus = RuntimeFocusInspector(texts: ["ghbdtn ", "привет ", "привет ", "ghbdtn "])
        let autoInjector = RuntimeInjector()
        let manualFocus = RuntimeFocusInspector(texts: ["ghbdtn ", "привет "])
        let manualInjector = RuntimeInjector()
        let runtime = makeRuntime(
            autoFocus: autoFocus,
            autoInjector: autoInjector,
            manualFocus: manualFocus,
            manualInjector: manualInjector
        )

        // Type the mistyped word plus its separator; automatic schedules a
        // pending correction that both coordinators have also tracked.
        typeWord("ghbdtn", into: runtime, in: environment())
        XCTAssertEqual(runtime.receive(.text(.init(keyCode: 50), output: " "), in: environment()), .scheduledPendingCorrection)
        XCTAssertTrue(runtime.performPendingCorrection(in: environment()))
        XCTAssertEqual(autoInjector.operations, [.backspace(7), .unicode("привет"), .unicode(" ")])

        // Double Shift: automatic reverses to the original, and manual must be
        // dropped so it cannot paste "привет" back over the restored "ghbdtn".
        let outcome = triggerDoubleShift(runtime, in: environment(activeLayoutID: "russian"))

        XCTAssertEqual(outcome, .commandApplied)
        XCTAssertEqual(autoInjector.operations.suffix(3), [.backspace(7), .unicode("ghbdtn"), .unicode(" ")])
        XCTAssertTrue(manualInjector.operations.isEmpty, "manual conversion must not apply a stale copy")
    }

    /// When automatic correction has nothing to reverse, the recognized command
    /// is routed to manual conversion, which applies it.
    func testCommandFallsThroughToManualWhenAutomaticHasNoReplacement() {
        let autoFocus = RuntimeFocusInspector(texts: [])
        let autoInjector = RuntimeInjector()
        let manualFocus = RuntimeFocusInspector(texts: ["ghbdtn ", "привет "])
        let manualInjector = RuntimeInjector()
        let runtime = makeRuntime(
            autoFocus: autoFocus,
            autoInjector: autoInjector,
            manualFocus: manualFocus,
            manualInjector: manualInjector
        )
        // Automation disabled: automatic never schedules, so it holds nothing.
        let env = environment(isAutomationEnabled: false)

        typeWord("ghbdtn", into: runtime, in: env)
        XCTAssertEqual(runtime.receive(.text(.init(keyCode: 50), output: " "), in: env), .ignored)

        let outcome = triggerDoubleShift(runtime, in: env)

        XCTAssertEqual(outcome, .commandApplied)
        XCTAssertTrue(autoInjector.operations.isEmpty)
        XCTAssertEqual(manualInjector.operations, [.backspace(7), .unicode("привет"), .unicode(" ")])
    }

    /// Two different physical Shift keys are not a Double Shift, so no
    /// coordinator applies anything.
    func testTwoDifferentShiftKeysDoNotApplyAnyCommand() {
        let manualFocus = RuntimeFocusInspector(texts: ["ghbdtn ", "привет "])
        let manualInjector = RuntimeInjector()
        let runtime = makeRuntime(
            autoFocus: RuntimeFocusInspector(texts: []),
            autoInjector: RuntimeInjector(),
            manualFocus: manualFocus,
            manualInjector: manualInjector
        )
        let env = environment(isAutomationEnabled: false)

        typeWord("ghbdtn", into: runtime, in: env)
        runtime.receive(.text(.init(keyCode: 50), output: " "), in: env)

        runtime.receive(.shiftDown(.left, milliseconds: 0), in: env)
        runtime.receive(.shiftUp(.left, milliseconds: 30), in: env)
        runtime.receive(.shiftDown(.right, milliseconds: 100), in: env)
        let outcome = runtime.receive(.shiftUp(.right, milliseconds: 130), in: env)

        XCTAssertEqual(outcome, .ignored)
        XCTAssertTrue(manualInjector.operations.isEmpty)
    }

    // MARK: - Helpers

    private func makeRuntime(
        autoFocus: RuntimeFocusInspector,
        autoInjector: RuntimeInjector,
        manualFocus: RuntimeFocusInspector,
        manualInjector: RuntimeInjector
    ) -> ConversionRuntime {
        let automatic = AutomaticCorrectionCoordinator(
            focusInspector: autoFocus,
            textInjector: autoInjector,
            inputSourceService: RuntimeInputSource(),
            detector: .init(resources: .minimum),
            translate: russianCandidate
        )
        let manual = ManualConversionCoordinator(
            focusInspector: manualFocus,
            textInjector: manualInjector,
            inputSourceService: RuntimeInputSource(),
            translate: russianCandidate
        )
        return ConversionRuntime(automatic: automatic, manual: manual)
    }

    private func typeWord(_ word: String, into runtime: ConversionRuntime, in environment: InputSessionEnvironment) {
        for (offset, character) in word.enumerated() {
            runtime.receive(.text(.init(keyCode: UInt16(offset + 1)), output: String(character)), in: environment)
        }
    }

    @discardableResult
    private func triggerDoubleShift(_ runtime: ConversionRuntime, in environment: InputSessionEnvironment) -> ConversionRuntime.Outcome {
        runtime.receive(.shiftDown(.left, milliseconds: 0), in: environment)
        runtime.receive(.shiftUp(.left, milliseconds: 30), in: environment)
        runtime.receive(.shiftDown(.left, milliseconds: 100), in: environment)
        return runtime.receive(.shiftUp(.left, milliseconds: 130), in: environment)
    }

    private func environment(
        activeLayoutID: String = "english",
        isAutomationEnabled: Bool = true
    ) -> InputSessionEnvironment {
        .init(
            configuration: .init(revision: 1, isAutomationEnabled: isAutomationEnabled, wordExceptions: []),
            focus: .init(applicationID: "TextEdit", elementID: "body", processID: 42, isSupported: true),
            policy: .init(allowsTracking: true),
            layouts: .init(
                pair: .init(english: .init(id: "english", name: "English"), russian: .init(id: "russian", name: "Russian")),
                availableLayoutIDs: ["english", "russian"],
                activeLayoutID: activeLayoutID
            )
        )
    }

    private func russianCandidate(_ layout: KeyboardLayout, _ stroke: KeyStroke) -> String? {
        switch layout.id {
        case "russian":
            return [1: "п", 2: "р", 3: "и", 4: "в", 5: "е", 6: "т"][stroke.keyCode]
        case "english":
            return [1: "h", 2: "e", 3: "l", 4: "l", 5: "o"][stroke.keyCode]
        default:
            return nil
        }
    }
}

private final class RuntimeFocusInspector: FocusInspector, @unchecked Sendable {
    private var texts: [String]
    private(set) var requestedCounts: [Int] = []

    init(texts: [String]) {
        self.texts = texts
    }

    func replacementProof(beforeCursorCount: Int) -> ReplacementProof {
        requestedCounts.append(beforeCursorCount)
        guard !texts.isEmpty else { return .opaque }
        return .exact(.init(
            processID: 42,
            elementID: "body",
            role: .textArea,
            isProtected: false,
            selection: .init(location: beforeCursorCount, length: 0),
            localTextBeforeCursor: texts.removeFirst()
        ))
    }
}

private final class RuntimeInjector: TextInjector, @unchecked Sendable {
    enum Operation: Equatable { case backspace(Int), unicode(String) }
    private(set) var operations: [Operation] = []

    func sendMarkedBackspaces(_ count: Int) -> Bool {
        operations.append(.backspace(count))
        return true
    }

    func sendMarkedUnicode(_ text: String) -> Bool {
        operations.append(.unicode(text))
        return true
    }
}

private final class RuntimeInputSource: InputSourceService, @unchecked Sendable {
    private(set) var selectedLayoutIDs: [String] = []

    func selectInputSource(id: String) -> Bool {
        selectedLayoutIDs.append(id)
        return true
    }
}
