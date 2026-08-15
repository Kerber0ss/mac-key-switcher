import XCTest
@testable import SwitcherCore

final class AutomaticCorrectionCoordinatorTests: XCTestCase {
    func testEmbeddedResourcesRecognizeObviousLayoutMistakesInBothDirections() {
        let detector = LanguageDetector(resources: .minimum)

        let correction = detector.decide(word: "ghbdtn", candidate: "привет")

        XCTAssertEqual(correction.decision, .correct)
        XCTAssertEqual(correction.scores.source, 0)
        XCTAssertGreaterThan(correction.scores.candidate, 0)
        XCTAssertEqual(correction.reasons, [.candidateKnown])
        XCTAssertEqual(detector.decide(word: "руддщ", candidate: "hello").decision, .correct)
        XCTAssertEqual(detector.decide(word: "hello", candidate: "руддщ").decision, .keep)
        XCTAssertEqual(detector.decide(word: "asdf", candidate: "фыва").decision, .uncertain)
    }

    func testPassedSeparatorSchedulesSafeReplacementAndKeepsItReversible() {
        let focus = SequencedFocusInspector(texts: ["ghbdtn ", "привет "])
        let injector = RecordingAutomaticTextInjector()
        let inputSource = RecordingAutomaticInputSourceService()
        let coordinator = AutomaticCorrectionCoordinator(
            focusInspector: focus,
            textInjector: injector,
            inputSourceService: inputSource,
            detector: .init(resources: .minimum),
            translate: russianCandidate
        )

        complete("ghbdtn", with: coordinator, in: environment())

        XCTAssertEqual(injector.operations, [])
        XCTAssertEqual(coordinator.performPendingCorrection(in: environment()), .replaced)
        XCTAssertEqual(injector.operations, [.backspace(7), .unicode("привет"), .unicode(" ")])
        XCTAssertEqual(inputSource.selectedLayoutIDs, ["russian"])

        XCTAssertEqual(triggerDoubleLeftShift(on: coordinator, in: environment(activeLayoutID: "russian")), .replaced)
        XCTAssertEqual(injector.operations.suffix(3), [.backspace(7), .unicode("ghbdtn"), .unicode(" ")])
        XCTAssertEqual(inputSource.selectedLayoutIDs, ["russian", "english"])
    }

    func testCorrectsAgainAfterTheUserReturnsToTheOriginalLayout() {
        let focus = SequencedFocusInspector(texts: ["ghbdtn ", "привет ", "руддщ ", "hello "])
        let injector = RecordingAutomaticTextInjector()
        let inputSource = RecordingAutomaticInputSourceService()
        let coordinator = AutomaticCorrectionCoordinator(
            focusInspector: focus,
            textInjector: injector,
            inputSourceService: inputSource,
            detector: .init(resources: .minimum),
            translate: russianCandidate
        )

        complete("ghbdtn", with: coordinator, in: environment())
        XCTAssertEqual(coordinator.performPendingCorrection(in: environment()), .replaced)

        complete("руддщ", with: coordinator, in: environment(activeLayoutID: "russian"))
        XCTAssertEqual(
            coordinator.performPendingCorrection(in: environment(activeLayoutID: "russian")),
            .replaced
        )

        XCTAssertEqual(inputSource.selectedLayoutIDs, ["russian", "english"])
        XCTAssertEqual(injector.operations.suffix(3), [.backspace(6), .unicode("hello"), .unicode(" ")])
    }

    func testPhysicalKeyCancelsPendingCorrectionBeforeAnyDeletion() {
        let focus = SequencedFocusInspector(texts: [])
        let injector = RecordingAutomaticTextInjector()
        let inputSource = RecordingAutomaticInputSourceService()
        let coordinator = AutomaticCorrectionCoordinator(
            focusInspector: focus,
            textInjector: injector,
            inputSourceService: inputSource,
            detector: .init(resources: .minimum),
            translate: russianCandidate
        )

        complete("ghbdtn", with: coordinator, in: environment())
        XCTAssertEqual(coordinator.receive(.text(.init(keyCode: 8), output: "x"), in: environment()), .cancelled)
        XCTAssertEqual(coordinator.performPendingCorrection(in: environment()), .ignored)
        XCTAssertTrue(focus.requestedCounts.isEmpty)
        XCTAssertTrue(injector.operations.isEmpty)
        XCTAssertTrue(inputSource.selectedLayoutIDs.isEmpty)
    }

    func testPendingCorrectionUsesExplicitOpaqueProofWhenTheFieldCannotReadLocalText() {
        let injector = RecordingAutomaticTextInjector()
        let inputSource = RecordingAutomaticInputSourceService()
        let coordinator = AutomaticCorrectionCoordinator(
            focusInspector: SequencedFocusInspector(texts: []),
            textInjector: injector,
            inputSourceService: inputSource,
            detector: .init(resources: .minimum),
            translate: russianCandidate
        )

        complete("ghbdtn", with: coordinator, in: environment())

        XCTAssertEqual(coordinator.performPendingCorrection(in: environment()), .replaced)
        XCTAssertEqual(injector.operations, [.backspace(7), .unicode("привет"), .unicode(" ")])
        XCTAssertEqual(inputSource.selectedLayoutIDs, ["russian"])
    }

    func testCorrectsInAnOpaqueUnprotectedFocus() {
        let injector = RecordingAutomaticTextInjector()
        let inputSource = RecordingAutomaticInputSourceService()
        let coordinator = AutomaticCorrectionCoordinator(
            focusInspector: OpaqueAutomaticFocusInspector(),
            textInjector: injector,
            inputSourceService: inputSource,
            detector: .init(resources: .minimum),
            translate: russianCandidate
        )

        complete("ghbdtn", with: coordinator, in: environment())

        XCTAssertEqual(coordinator.performPendingCorrection(in: environment()), .replaced)
        XCTAssertEqual(injector.operations, [.backspace(7), .unicode("привет"), .unicode(" ")])
        XCTAssertEqual(inputSource.selectedLayoutIDs, ["russian"])
    }

    func testKeepsLunWhenTheBundledRussianDictionaryRecognizesIt() {
        let injector = RecordingAutomaticTextInjector()
        let inputSource = RecordingAutomaticInputSourceService()
        let coordinator = AutomaticCorrectionCoordinator(
            focusInspector: SequencedFocusInspector(texts: ["лун ", "key "]),
            textInjector: injector,
            inputSourceService: inputSource,
            detector: .init(resources: .minimum),
            translate: { layout, stroke in
                guard layout.id == "russian" else { return nil }
                return [40: "k", 14: "e", 16: "y"][stroke.keyCode]
            }
        )

        for (keyCode, output) in [(40, "л"), (14, "у"), (16, "н"), (49, " ")] {
            _ = coordinator.receive(.text(.init(keyCode: UInt16(keyCode)), output: output), in: environment())
        }

        XCTAssertEqual(coordinator.performPendingCorrection(in: environment()), .ignored)
        XCTAssertTrue(injector.operations.isEmpty)
        XCTAssertTrue(inputSource.selectedLayoutIDs.isEmpty)
    }

    func testPunctuationAlsoSchedulesCorrectionOnlyAfterItHasPassed() {
        let coordinator = AutomaticCorrectionCoordinator(
            focusInspector: SequencedFocusInspector(texts: []),
            textInjector: RecordingAutomaticTextInjector(),
            inputSourceService: RecordingAutomaticInputSourceService(),
            detector: .init(resources: .minimum),
            translate: russianCandidate
        )

        for (offset, character) in "ghbdtn".enumerated() {
            coordinator.receive(.text(.init(keyCode: UInt16(offset + 1)), output: String(character)), in: environment())
        }

        XCTAssertEqual(coordinator.receive(.text(.init(keyCode: 50), output: "!"), in: environment()), .pending)
    }

    func testKeepAndUncertainDecisionsDoNotDeleteOrSelectLayout() {
        let focus = SequencedFocusInspector(texts: [])
        let injector = RecordingAutomaticTextInjector()
        let inputSource = RecordingAutomaticInputSourceService()
        let coordinator = AutomaticCorrectionCoordinator(
            focusInspector: focus,
            textInjector: injector,
            inputSourceService: inputSource,
            detector: .init(resources: .minimum),
            translate: { layout, stroke in
                guard layout.id == "russian" else { return nil }
                return [1: "р", 2: "у", 3: "д", 4: "д", 5: "щ"][stroke.keyCode]
            }
        )

        complete("hello", expecting: .ignored, with: coordinator, in: environment())
        complete("asdf", expecting: .ignored, with: coordinator, in: environment())

        XCTAssertTrue(focus.requestedCounts.isEmpty)
        XCTAssertTrue(injector.operations.isEmpty)
        XCTAssertTrue(inputSource.selectedLayoutIDs.isEmpty)
    }

    func testAutomationOffAndWordExceptionDoNotScheduleCorrection() {
        let coordinator = AutomaticCorrectionCoordinator(
            focusInspector: SequencedFocusInspector(texts: []),
            textInjector: RecordingAutomaticTextInjector(),
            inputSourceService: RecordingAutomaticInputSourceService(),
            detector: .init(resources: .minimum),
            translate: russianCandidate
        )

        complete("ghbdtn", expecting: .ignored, with: coordinator, in: environment(isAutomationEnabled: false))
        complete("ghbdtn", expecting: .ignored, with: coordinator, in: environment(wordExceptions: ["GHBDTN"]))
    }

    func testSettingsRevisionClosesAReversibleAutomaticReplacement() {
        let focus = SequencedFocusInspector(texts: ["ghbdtn ", "привет "])
        let injector = RecordingAutomaticTextInjector()
        let coordinator = AutomaticCorrectionCoordinator(
            focusInspector: focus,
            textInjector: injector,
            inputSourceService: RecordingAutomaticInputSourceService(),
            detector: .init(resources: .minimum),
            translate: russianCandidate
        )

        complete("ghbdtn", with: coordinator, in: environment())
        XCTAssertEqual(coordinator.performPendingCorrection(in: environment()), .replaced)

        XCTAssertEqual(
            triggerDoubleLeftShift(on: coordinator, in: environment(activeLayoutID: "russian", revision: 2)),
            .ignored
        )
        XCTAssertEqual(injector.operations, [.backspace(7), .unicode("привет"), .unicode(" ")])
    }

    func testCloseSessionAfterLostInputCancelsPendingWithoutInjectionOrLayoutChange() {
        let focus = SequencedFocusInspector(texts: [])
        let injector = RecordingAutomaticTextInjector()
        let inputSource = RecordingAutomaticInputSourceService()
        let coordinator = AutomaticCorrectionCoordinator(
            focusInspector: focus,
            textInjector: injector,
            inputSourceService: inputSource,
            detector: .init(resources: .minimum),
            translate: russianCandidate
        )

        complete("ghbdtn", with: coordinator, in: environment())
        coordinator.closeSession()

        XCTAssertEqual(coordinator.performPendingCorrection(in: environment()), .ignored)
        XCTAssertTrue(focus.requestedCounts.isEmpty)
        XCTAssertTrue(injector.operations.isEmpty)
        XCTAssertTrue(inputSource.selectedLayoutIDs.isEmpty)
    }

    func testEnvironmentChangesCancelPendingWithoutInjectionOrLayoutChange() {
        let focus = SequencedFocusInspector(texts: [])
        let injector = RecordingAutomaticTextInjector()
        let inputSource = RecordingAutomaticInputSourceService()
        let coordinator = AutomaticCorrectionCoordinator(
            focusInspector: focus,
            textInjector: injector,
            inputSourceService: inputSource,
            detector: .init(resources: .minimum),
            translate: russianCandidate
        )
        let original = environment()
        let changedEnvironments = [
            environment(activeLayoutID: "russian"),
            environment(revision: 2),
            .init(configuration: original.configuration, focus: .init(applicationID: "TextEdit", elementID: "other", processID: 42, isSupported: true), policy: original.policy, layouts: original.layouts),
            .init(configuration: original.configuration, focus: original.focus, policy: .init(allowsAutomaticCorrection: false, allowsManualConversion: true, revision: 2), layouts: original.layouts),
        ]

        for changed in changedEnvironments {
            complete("ghbdtn", with: coordinator, in: original)
            XCTAssertEqual(coordinator.performPendingCorrection(in: changed), .ignored)
        }
        XCTAssertTrue(focus.requestedCounts.isEmpty)
        XCTAssertTrue(injector.operations.isEmpty)
        XCTAssertTrue(inputSource.selectedLayoutIDs.isEmpty)
    }

    func testLayoutSelectionFailureClosesTheSessionAfterVerifiedInsertion() {
        let focus = SequencedFocusInspector(texts: ["ghbdtn ", "привет "])
        let injector = RecordingAutomaticTextInjector()
        let inputSource = FailingAutomaticInputSourceService()
        let coordinator = AutomaticCorrectionCoordinator(
            focusInspector: focus,
            textInjector: injector,
            inputSourceService: inputSource,
            detector: .init(resources: .minimum),
            translate: russianCandidate
        )

        complete("ghbdtn", with: coordinator, in: environment())

        XCTAssertEqual(coordinator.performPendingCorrection(in: environment()), .layoutSelectionFailed)
        XCTAssertEqual(coordinator.availability, .disabledAfterFailure)
        XCTAssertEqual(injector.operations, [.backspace(7), .unicode("привет"), .unicode(" ")])
        XCTAssertEqual(inputSource.selectedLayoutIDs, ["russian"])
        XCTAssertEqual(coordinator.receive(.text(.init(keyCode: 1), output: "g"), in: environment()), .ignored)
    }

    func testDelayedPostVerificationDoesNotBlockTheNextWordInTheSameField() {
        let focus = SequencedFocusInspector(texts: ["ghbdtn ", "привет ", "ghbdtn ", "привет "])
        let injector = RecordingAutomaticTextInjector()
        let coordinator = AutomaticCorrectionCoordinator(
            focusInspector: focus,
            textInjector: injector,
            inputSourceService: RecordingAutomaticInputSourceService(),
            detector: .init(resources: .minimum),
            translate: russianCandidate
        )
        let original = environment()

        complete("ghbdtn", with: coordinator, in: original)
        XCTAssertEqual(coordinator.performPendingCorrection(in: original), .replaced)

        complete("ghbdtn", expecting: .pending, with: coordinator, in: original)
        XCTAssertEqual(coordinator.performPendingCorrection(in: original), .replaced)
        XCTAssertEqual(
            injector.operations,
            [.backspace(7), .unicode("привет"), .unicode(" "), .backspace(7), .unicode("привет"), .unicode(" ")]
        )
    }

    func testPostVerificationFailureClosesTheAutomaticRuntimeWithoutSelectingLayout() {
        let injector = RecordingAutomaticTextInjector()
        let inputSource = RecordingAutomaticInputSourceService()
        let coordinator = AutomaticCorrectionCoordinator(
            focusInspector: SequencedFocusInspector(texts: ["ghbdtn ", "не совпало"]),
            textInjector: injector,
            inputSourceService: inputSource,
            detector: .init(resources: .minimum),
            translate: russianCandidate
        )

        complete("ghbdtn", with: coordinator, in: environment())

        XCTAssertEqual(coordinator.performPendingCorrection(in: environment()), .postVerificationFailed)
        XCTAssertEqual(coordinator.availability, .disabledAfterFailure)
        XCTAssertEqual(injector.operations, [.backspace(7), .unicode("привет"), .unicode(" ")])
        XCTAssertTrue(inputSource.selectedLayoutIDs.isEmpty)
    }

    func testPartialInjectionFailureClosesTheAutomaticRuntimeWithoutRollback() {
        let injector = FailingAutomaticTextInjector()
        let coordinator = AutomaticCorrectionCoordinator(
            focusInspector: SequencedFocusInspector(texts: ["ghbdtn "]),
            textInjector: injector,
            inputSourceService: RecordingAutomaticInputSourceService(),
            detector: .init(resources: .minimum),
            translate: russianCandidate
        )

        complete("ghbdtn", with: coordinator, in: environment())

        XCTAssertEqual(coordinator.performPendingCorrection(in: environment()), .injectionFailed)
        XCTAssertEqual(coordinator.availability, .disabledAfterFailure)
        XCTAssertEqual(injector.operations, [.backspace(7), .unicode("привет")])
    }

    private func complete(
        _ word: String,
        expecting result: AutomaticCorrectionResult = .pending,
        with coordinator: AutomaticCorrectionCoordinator,
        in environment: InputSessionEnvironment
    ) {
        for (offset, character) in word.enumerated() {
            coordinator.receive(.text(.init(keyCode: UInt16(offset + 1)), output: String(character)), in: environment)
        }
        XCTAssertEqual(coordinator.receive(.text(.init(keyCode: 50), output: " "), in: environment), result)
    }

    private func environment(
        activeLayoutID: String = "english",
        isAutomationEnabled: Bool = true,
        wordExceptions: Set<String> = [],
        revision: UInt64 = 1
    ) -> InputSessionEnvironment {
        .init(
            configuration: .init(
                revision: revision,
                isAutomationEnabled: isAutomationEnabled,
                wordExceptions: wordExceptions
            ),
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
            return [1: "п", 2: "р", 3: "и", 4: "в", 5: "е", 6: "т", 7: "х", 8: "ч"][stroke.keyCode]
        case "english":
            return [1: "h", 2: "e", 3: "l", 4: "l", 5: "o"][stroke.keyCode]
        default:
            return nil
        }
    }

    /// Command recognition (Double Shift / custom shortcut) now lives in the
    /// single `ManualCommandRecognizer` layer, so triggering a command against a
    /// coordinator is just handing it the ready "command performed" signal.
    @discardableResult
    private func triggerDoubleLeftShift(
        on coordinator: AutomaticCorrectionCoordinator,
        in environment: InputSessionEnvironment
    ) -> AutomaticCorrectionResult {
        coordinator.performCommand(in: environment)
    }
}

private final class SequencedFocusInspector: FocusInspector, @unchecked Sendable {
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

private final class OpaqueAutomaticFocusInspector: FocusInspector, @unchecked Sendable {
    func replacementProof(beforeCursorCount: Int) -> ReplacementProof {
        .opaque
    }
}

private final class RecordingAutomaticTextInjector: TextInjector, @unchecked Sendable {
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

private final class RecordingAutomaticInputSourceService: InputSourceService, @unchecked Sendable {
    private(set) var selectedLayoutIDs: [String] = []

    func selectInputSource(id: String) -> Bool {
        selectedLayoutIDs.append(id)
        return true
    }
}

private final class FailingAutomaticInputSourceService: InputSourceService, @unchecked Sendable {
    private(set) var selectedLayoutIDs: [String] = []

    func selectInputSource(id: String) -> Bool {
        selectedLayoutIDs.append(id)
        return false
    }
}

private final class FailingAutomaticTextInjector: TextInjector, @unchecked Sendable {
    enum Operation: Equatable { case backspace(Int), unicode(String) }
    private(set) var operations: [Operation] = []

    func sendMarkedBackspaces(_ count: Int) -> Bool {
        operations.append(.backspace(count))
        return true
    }

    func sendMarkedUnicode(_ text: String) -> Bool {
        operations.append(.unicode(text))
        return false
    }
}
