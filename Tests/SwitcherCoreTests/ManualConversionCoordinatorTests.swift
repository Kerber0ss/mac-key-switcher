import XCTest
@testable import SwitcherCore

final class ManualConversionCoordinatorTests: XCTestCase {
    func testDoubleShiftReplacesConfirmedCompletedWordThenSelectsCandidateLayout() {
        let focus = RecordingFocusInspector(
            inspection: .init(
                processID: 42,
                elementID: "body",
                role: .textArea,
                isProtected: false,
                selection: .init(location: 7, length: 0),
                localTextBeforeCursor: "gh "
            ),
            postInsertionText: "пр "
        )
        let injector = RecordingTextInjector()
        let inputSource = RecordingInputSourceService()
        let coordinator = ManualConversionCoordinator(
            focusInspector: focus,
            textInjector: injector,
            inputSourceService: inputSource,
            translate: { _, stroke in stroke.keyCode == 1 ? "п" : "р" }
        )
        let environment = InputSessionEnvironment(
            configuration: .init(revision: 1, isEnabled: true),
            focus: .init(applicationID: "TextEdit", elementID: "body", processID: 42, isSupported: true),
            policy: .init(allowsTracking: true),
            layouts: .init(
                pair: .init(
                    english: .init(id: "english", name: "English"),
                    russian: .init(id: "russian", name: "Russian")
                ),
                availableLayoutIDs: ["english", "russian"],
                activeLayoutID: "english"
            )
        )

        coordinator.receive(.text(.init(keyCode: 1), output: "g"), in: environment)
        coordinator.receive(.text(.init(keyCode: 2), output: "h"), in: environment)
        coordinator.receive(.text(.init(keyCode: 3), output: " "), in: environment)
        let result = coordinator.performCommand(in: environment)

        XCTAssertEqual(result, .replaced)
        XCTAssertEqual(focus.requestedCounts, [3, 3])
        XCTAssertEqual(injector.operations, [.backspace(3), .unicode("пр"), .unicode(" ")])
        XCTAssertEqual(inputSource.selectedLayoutIDs, ["russian"])
    }

    func testManualCommandReplacesTheCurrentWordWithoutASeparator() {
        let focus = inspector(text: "gh", postInsertionText: "пр")
        let injector = RecordingTextInjector()
        let inputSource = RecordingInputSourceService()
        let coordinator = coordinator(focus: focus, injector: injector, inputSource: inputSource)
        let environment = environment()

        coordinator.receive(.text(.init(keyCode: 1), output: "g"), in: environment)
        coordinator.receive(.text(.init(keyCode: 2), output: "h"), in: environment)

        XCTAssertEqual(coordinator.performCommand(in: environment), .replaced)
        XCTAssertEqual(injector.operations, [.backspace(2), .unicode("пр")])
        XCTAssertEqual(inputSource.selectedLayoutIDs, ["russian"])
    }

    func testManualCommandReplacesContinuouslyObservedOpaqueInput() {
        let injector = RecordingTextInjector()
        let inputSource = RecordingInputSourceService()
        let coordinator = coordinator(
            focus: OpaqueManualFocusInspector(),
            injector: injector,
            inputSource: inputSource
        )
        let environment = environment()

        coordinator.receive(.text(.init(keyCode: 1), output: "g"), in: environment)
        coordinator.receive(.text(.init(keyCode: 2), output: "h"), in: environment)

        XCTAssertEqual(coordinator.performCommand(in: environment), .replaced)
        XCTAssertEqual(injector.operations, [.backspace(2), .unicode("пр")])
        XCTAssertEqual(inputSource.selectedLayoutIDs, ["russian"])
    }

    func testWordExceptionNeverBlocksManualConversion() {
        let injector = RecordingTextInjector()
        let coordinator = coordinator(
            focus: inspector(text: "gh", postInsertionText: "пр"),
            injector: injector,
            inputSource: RecordingInputSourceService()
        )
        let environment = environment(wordExceptions: ["GH"])

        coordinator.receive(.text(.init(keyCode: 1), output: "g"), in: environment)
        coordinator.receive(.text(.init(keyCode: 2), output: "h"), in: environment)

        XCTAssertEqual(coordinator.performCommand(in: environment), .replaced)
        XCTAssertEqual(injector.operations, [.backspace(2), .unicode("пр")])
    }

    func testRejectsHeldDifferentInterruptedAndSlowShiftSequences() {
        let focus = inspector()
        let injector = RecordingTextInjector()
        let inputSource = RecordingInputSourceService()
        let coordinator = coordinator(focus: focus, injector: injector, inputSource: inputSource)
        let environment = environment()
        complete("gh", with: coordinator, in: environment)

        coordinator.receive(.shiftDown(.left, milliseconds: 0), in: environment)
        coordinator.receive(.shiftDown(.left, milliseconds: 10), in: environment)
        coordinator.receive(.shiftUp(.left, milliseconds: 20), in: environment)
        coordinator.receive(.shiftDown(.right, milliseconds: 30), in: environment)
        coordinator.receive(.shiftUp(.right, milliseconds: 40), in: environment)
        coordinator.receive(.shiftDown(.left, milliseconds: 50), in: environment)
        coordinator.receive(.shiftUp(.left, milliseconds: 60), in: environment)
        coordinator.receive(.text(.init(keyCode: 4), output: " "), in: environment)
        coordinator.receive(.shiftDown(.left, milliseconds: 70), in: environment)
        coordinator.receive(.shiftUp(.left, milliseconds: 80), in: environment)
        coordinator.receive(.shiftDown(.left, milliseconds: 500), in: environment)
        coordinator.receive(.shiftUp(.left, milliseconds: 510), in: environment)

        XCTAssertTrue(injector.operations.isEmpty)
        XCTAssertTrue(inputSource.selectedLayoutIDs.isEmpty)
    }

    func testConvertsTechnicalTokensButNeverSequencesLongerThanSixtyFourKeys() {
        let technicalFocus = inspector(text: "g1 ", postInsertionText: "пр ")
        let technicalInjector = RecordingTextInjector()
        let technicalSource = RecordingInputSourceService()
        let technical = coordinator(focus: technicalFocus, injector: technicalInjector, inputSource: technicalSource)
        let environment = environment()
        complete("g1", with: technical, in: environment)
        triggerDoubleLeftShift(on: technical, in: environment)

        XCTAssertEqual(technicalInjector.operations, [.backspace(3), .unicode("пр"), .unicode(" ")])

        let longFocus = inspector(text: String(repeating: "g", count: 64), postInsertionText: "")
        let longInjector = RecordingTextInjector()
        let long = coordinator(focus: longFocus, injector: longInjector, inputSource: RecordingInputSourceService())
        complete(String(repeating: "g", count: 65), with: long, in: environment)
        triggerDoubleLeftShift(on: long, in: environment)

        XCTAssertTrue(longInjector.operations.isEmpty)
        XCTAssertTrue(longFocus.requestedCounts.isEmpty)
    }

    func testRejectsAnyUnprovenFocusedContextWithoutInjecting() {
        let cases: [FocusInspection] = [
            .init(processID: 99, elementID: "body", role: .textArea, isProtected: false, selection: .init(location: 2, length: 0), localTextBeforeCursor: "gh"),
            .init(processID: 42, elementID: "other", role: .textArea, isProtected: false, selection: .init(location: 2, length: 0), localTextBeforeCursor: "gh"),
            .init(processID: 42, elementID: "body", role: .unsupported, isProtected: false, selection: .init(location: 2, length: 0), localTextBeforeCursor: "gh"),
            .init(processID: 42, elementID: "body", role: .textArea, isEditable: false, isProtected: false, selection: .init(location: 2, length: 0), localTextBeforeCursor: "gh"),
            .init(processID: 42, elementID: "body", role: .textArea, isProtected: true, selection: .init(location: 2, length: 0), localTextBeforeCursor: "gh"),
            .init(processID: 42, elementID: "body", role: .textArea, isProtected: false, selection: .init(location: 2, length: 1), localTextBeforeCursor: "gh"),
            .init(processID: 42, elementID: "body", role: .textArea, isProtected: false, selection: .init(location: 2, length: 0), localTextBeforeCursor: "other"),
        ]

        for inspection in cases {
            let focus = RecordingFocusInspector(inspection: inspection, postInsertionText: "пр")
            let injector = RecordingTextInjector()
            let coordinator = coordinator(focus: focus, injector: injector, inputSource: RecordingInputSourceService())
            let environment = environment()
            complete("gh", with: coordinator, in: environment)
            triggerDoubleLeftShift(on: coordinator, in: environment)

            XCTAssertTrue(injector.operations.isEmpty)
            XCTAssertEqual(coordinator.availability, .disabledAfterFailure)
        }
    }

    func testPostInsertionMismatchDoesNotSelectLayout() {
        let focus = inspector(postInsertionText: "не совпало")
        let injector = RecordingTextInjector()
        let inputSource = RecordingInputSourceService()
        let coordinator = coordinator(focus: focus, injector: injector, inputSource: inputSource)
        let environment = environment()
        complete("gh", with: coordinator, in: environment)

        XCTAssertEqual(triggerDoubleLeftShift(on: coordinator, in: environment), .postVerificationFailed)
        XCTAssertEqual(injector.operations, [.backspace(3), .unicode("пр"), .unicode(" ")])
        XCTAssertTrue(inputSource.selectedLayoutIDs.isEmpty)
        XCTAssertEqual(coordinator.availability, .disabledAfterFailure)
        XCTAssertEqual(triggerDoubleLeftShift(on: coordinator, in: environment), .ignored)
        XCTAssertEqual(injector.operations, [.backspace(3), .unicode("пр"), .unicode(" ")])
    }

    func testDoesNotTrackOrModifyAnUnsupportedProtectedContext() {
        let focus = inspector()
        let injector = RecordingTextInjector()
        let coordinator = coordinator(focus: focus, injector: injector, inputSource: RecordingInputSourceService())
        let environment = environment(isSupported: false)
        complete("gh", with: coordinator, in: environment)
        triggerDoubleLeftShift(on: coordinator, in: environment)

        XCTAssertTrue(focus.requestedCounts.isEmpty)
        XCTAssertTrue(injector.operations.isEmpty)
    }

    func testManualCommandRefusesAContextThatBecomesUnsupportedBeforeConfirmation() {
        let focus = inspector()
        let injector = RecordingTextInjector()
        let coordinator = coordinator(focus: focus, injector: injector, inputSource: RecordingInputSourceService())
        let supported = environment()
        let unsupported = environment(isSupported: false)

        complete("gh", with: coordinator, in: supported)

        XCTAssertEqual(triggerDoubleLeftShift(on: coordinator, in: unsupported), .ignored)
        XCTAssertTrue(injector.operations.isEmpty)
    }

    func testDoubleShiftTogglesOneReplacementBackAndForwardWithItsLayouts() {
        let focus = SequenceFocusInspector(texts: ["gh ", "пр ", "пр ", "gh ", "gh ", "пр "])
        let injector = RecordingTextInjector()
        let inputSource = RecordingInputSourceService()
        let coordinator = coordinator(focus: focus, injector: injector, inputSource: inputSource)

        complete("gh", with: coordinator, in: environment())
        XCTAssertEqual(triggerDoubleLeftShift(on: coordinator, in: environment()), .replaced)
        XCTAssertEqual(triggerDoubleLeftShift(on: coordinator, in: environment(activeLayoutID: "russian")), .replaced)
        XCTAssertEqual(triggerDoubleLeftShift(on: coordinator, in: environment()), .replaced)

        XCTAssertEqual(focus.requestedCounts, [3, 3, 3, 3, 3, 3])
        XCTAssertEqual(injector.operations, [
            .backspace(3), .unicode("пр"), .unicode(" "),
            .backspace(3), .unicode("gh"), .unicode(" "),
            .backspace(3), .unicode("пр"), .unicode(" "),
        ])
        XCTAssertEqual(inputSource.selectedLayoutIDs, ["russian", "english", "russian"])
    }

    func testManualCommandKeepsTogglingWhenTheFocusedFieldUpdatesAfterOneVerificationPoll() {
        var texts = ["gh ", "gh ", "пр "]
        for _ in 0 ..< 10 {
            let current = texts.last == "пр " ? "пр " : "gh "
            let next = current == "пр " ? "gh " : "пр "
            texts.append(contentsOf: [current, current, next])
        }
        let focus = SequenceFocusInspector(texts: texts)
        let injector = RecordingTextInjector()
        let inputSource = RecordingInputSourceService()
        let coordinator = coordinator(focus: focus, injector: injector, inputSource: inputSource)

        complete("gh", with: coordinator, in: environment())
        XCTAssertEqual(coordinator.performCommand(in: environment()), .replaced)
        for index in 0 ..< 10 {
            let layout = index.isMultiple(of: 2) ? "russian" : "english"
            XCTAssertEqual(coordinator.performCommand(in: environment(activeLayoutID: layout)), .replaced)
        }

        XCTAssertEqual(inputSource.selectedLayoutIDs.count, 11)
        XCTAssertEqual(coordinator.availability, .available)
    }

    func testToggleRemainsAvailableWhenAutomationIsDisabled() {
        let focus = SequenceFocusInspector(texts: ["gh ", "пр ", "пр ", "gh "])
        let injector = RecordingTextInjector()
        let inputSource = RecordingInputSourceService()
        let coordinator = coordinator(focus: focus, injector: injector, inputSource: inputSource)

        complete("gh", with: coordinator, in: environment())
        XCTAssertEqual(triggerDoubleLeftShift(on: coordinator, in: environment()), .replaced)
        XCTAssertEqual(
            triggerDoubleLeftShift(on: coordinator, in: environment(isEnabled: false, activeLayoutID: "russian")),
            .replaced
        )
        XCTAssertEqual(inputSource.selectedLayoutIDs, ["russian", "english"])
    }

    func testManualConversionStartsWhenAutomationIsDisabled() {
        let focus = inspector()
        let injector = RecordingTextInjector()
        let inputSource = RecordingInputSourceService()
        let coordinator = coordinator(focus: focus, injector: injector, inputSource: inputSource)
        let environment = environment(isEnabled: false)

        complete("gh", with: coordinator, in: environment)

        XCTAssertEqual(triggerDoubleLeftShift(on: coordinator, in: environment), .replaced)
        XCTAssertEqual(injector.operations, [.backspace(3), .unicode("пр"), .unicode(" ")])
        XCTAssertEqual(inputSource.selectedLayoutIDs, ["russian"])
    }

    func testTogglePreservesUpToSixteenTrailingSpacesAndPunctuation() {
        let appendedSuffix = String(repeating: " ", count: 14) + "!"
        let suffix = " " + appendedSuffix
        let focus = SequenceFocusInspector(texts: ["gh ", "пр ", "пр" + suffix, "gh" + suffix])
        let injector = RecordingTextInjector()
        let coordinator = coordinator(focus: focus, injector: injector, inputSource: RecordingInputSourceService())

        complete("gh", with: coordinator, in: environment())
        XCTAssertEqual(triggerDoubleLeftShift(on: coordinator, in: environment()), .replaced)
        for keyCode in 1 ... 14 {
            coordinator.receive(.text(.init(keyCode: UInt16(keyCode)), output: " "), in: environment(activeLayoutID: "russian"))
        }
        coordinator.receive(.text(.init(keyCode: 15), output: "!"), in: environment(activeLayoutID: "russian"))

        XCTAssertEqual(triggerDoubleLeftShift(on: coordinator, in: environment(activeLayoutID: "russian")), .replaced)
        XCTAssertEqual(focus.requestedCounts, [3, 3, 18, 18])
        XCTAssertEqual(injector.operations, [
            .backspace(3), .unicode("пр"), .unicode(" "),
            .backspace(18), .unicode("gh"), .unicode(suffix),
        ])
    }

    func testContentEditingBreaksAndAnOverlongSuffixClosesTheReplacement() {
        let focus = SequenceFocusInspector(texts: ["gh ", "пр "])
        let injector = RecordingTextInjector()
        let contentCoordinator = coordinator(focus: focus, injector: injector, inputSource: RecordingInputSourceService())

        complete("gh", with: contentCoordinator, in: environment())
        XCTAssertEqual(triggerDoubleLeftShift(on: contentCoordinator, in: environment()), .replaced)
        contentCoordinator.receive(.text(.init(keyCode: 3), output: "x"), in: environment(activeLayoutID: "russian"))

        XCTAssertEqual(triggerDoubleLeftShift(on: contentCoordinator, in: environment(activeLayoutID: "russian")), .ignored)
        XCTAssertEqual(focus.requestedCounts, [3, 3])

        let suffixFocus = SequenceFocusInspector(texts: ["gh ", "пр "])
        let suffixInjector = RecordingTextInjector()
        let suffixCoordinator = coordinator(focus: suffixFocus, injector: suffixInjector, inputSource: RecordingInputSourceService())
        complete("gh", with: suffixCoordinator, in: environment())
        XCTAssertEqual(triggerDoubleLeftShift(on: suffixCoordinator, in: environment()), .replaced)
        for keyCode in 1 ... 17 {
            suffixCoordinator.receive(.text(.init(keyCode: UInt16(keyCode)), output: " "), in: environment(activeLayoutID: "russian"))
        }

        XCTAssertEqual(triggerDoubleLeftShift(on: suffixCoordinator, in: environment(activeLayoutID: "russian")), .ignored)
        XCTAssertEqual(suffixFocus.requestedCounts, [3, 3])
        XCTAssertEqual(suffixInjector.operations, [.backspace(3), .unicode("пр"), .unicode(" ")])
    }

    func testInputBreakAndUnconfirmedReplacementTextRefuseToggling() {
        let focus = SequenceFocusInspector(texts: ["gh ", "пр ", "not candidate"])
        let injector = RecordingTextInjector()
        let coordinator = coordinator(focus: focus, injector: injector, inputSource: RecordingInputSourceService())

        complete("gh", with: coordinator, in: environment())
        XCTAssertEqual(triggerDoubleLeftShift(on: coordinator, in: environment()), .replaced)
        XCTAssertEqual(triggerDoubleLeftShift(on: coordinator, in: environment(activeLayoutID: "russian")), .rejected)
        coordinator.receive(.navigation, in: environment(activeLayoutID: "russian"))

        XCTAssertEqual(triggerDoubleLeftShift(on: coordinator, in: environment(activeLayoutID: "russian")), .ignored)
        XCTAssertEqual(focus.requestedCounts, [3, 3, 3])
        XCTAssertEqual(injector.operations, [.backspace(3), .unicode("пр"), .unicode(" ")])
    }

    func testClosingAnUnreliableEventStreamDropsTheLastCompletedWord() {
        let focus = inspector()
        let injector = RecordingTextInjector()
        let coordinator = coordinator(focus: focus, injector: injector, inputSource: RecordingInputSourceService())
        let environment = environment()

        complete("gh", with: coordinator, in: environment)
        coordinator.closeSession()

        XCTAssertEqual(triggerDoubleLeftShift(on: coordinator, in: environment), .ignored)
        XCTAssertTrue(injector.operations.isEmpty)
    }

    /// A word whose grapheme count differs from its UTF-16 length must request
    /// the AX range in UTF-16 code units, otherwise the read-back range is
    /// misaligned against the composite character and the exact proof fails.
    func testCompositeUnicodeWordRequestsAXRangeInUTF16CodeUnits() {
        // Decomposed "é": one grapheme cluster, two UTF-16 code units.
        let composed = "e\u{0301}"
        let focus = UTF16FieldFocusInspector(fields: [composed + " ", "ф "])
        let injector = RecordingTextInjector()
        let inputSource = RecordingInputSourceService()
        let coordinator = ManualConversionCoordinator(
            focusInspector: focus,
            textInjector: injector,
            inputSourceService: inputSource,
            translate: { _, stroke in stroke.keyCode == 1 ? "ф" : nil }
        )
        let environment = environment()

        coordinator.receive(.text(.init(keyCode: 1), output: composed), in: environment)
        coordinator.receive(.text(.init(keyCode: 50), output: " "), in: environment)

        XCTAssertEqual(coordinator.performCommand(in: environment), .replaced)
        // AX range is requested in UTF-16 units: "é " = 3 units, "ф " = 2 units.
        XCTAssertEqual(focus.requestedCounts, [3, 2])
        // Backspaces stay in grapheme clusters: "é" + " " = 2 clusters.
        XCTAssertEqual(injector.operations, [.backspace(2), .unicode("ф"), .unicode(" ")])
        XCTAssertEqual(inputSource.selectedLayoutIDs, ["russian"])
    }

    /// With composite Unicode present, a field whose read-back range does not
    /// match the expected text still fails closed without injecting anything.
    func testCompositeUnicodeMismatchFailsClosedWithoutInjection() {
        let composed = "e\u{0301}"
        let focus = UTF16FieldFocusInspector(fields: ["xy "])
        let injector = RecordingTextInjector()
        let inputSource = RecordingInputSourceService()
        let coordinator = ManualConversionCoordinator(
            focusInspector: focus,
            textInjector: injector,
            inputSourceService: inputSource,
            translate: { _, stroke in stroke.keyCode == 1 ? "ф" : nil }
        )
        let environment = environment()

        coordinator.receive(.text(.init(keyCode: 1), output: composed), in: environment)
        coordinator.receive(.text(.init(keyCode: 50), output: " "), in: environment)

        XCTAssertEqual(coordinator.performCommand(in: environment), .rejected)
        // The range was still requested in UTF-16 units before rejecting.
        XCTAssertEqual(focus.requestedCounts, [3])
        XCTAssertTrue(injector.operations.isEmpty)
        XCTAssertTrue(inputSource.selectedLayoutIDs.isEmpty)
        XCTAssertEqual(coordinator.availability, .disabledAfterFailure)
    }

    private func environment(
        isSupported: Bool = true,
        isEnabled: Bool = true,
        activeLayoutID: String = "english",
        wordExceptions: Set<String> = []
    ) -> InputSessionEnvironment {
        .init(
            configuration: .init(revision: 1, isAutomationEnabled: isEnabled, wordExceptions: wordExceptions),
            focus: .init(applicationID: "TextEdit", elementID: "body", processID: 42, isSupported: isSupported),
            policy: .init(allowsTracking: true),
            layouts: .init(
                pair: .init(english: .init(id: "english", name: "English"), russian: .init(id: "russian", name: "Russian")),
                availableLayoutIDs: ["english", "russian"],
                activeLayoutID: activeLayoutID
            )
        )
    }

    private func inspector(text: String = "gh ", postInsertionText: String = "пр ") -> RecordingFocusInspector {
        .init(
            inspection: .init(
                processID: 42,
                elementID: "body",
                role: .textArea,
                isProtected: false,
                selection: .init(location: text.count, length: 0),
                localTextBeforeCursor: text
            ),
            postInsertionText: postInsertionText
        )
    }

    private func coordinator(
        focus: FocusInspector,
        injector: RecordingTextInjector,
        inputSource: RecordingInputSourceService
    ) -> ManualConversionCoordinator {
        .init(
            focusInspector: focus,
            textInjector: injector,
            inputSourceService: inputSource,
            translate: { _, stroke in
                switch stroke.keyCode {
                case 1: "п"
                case 2: "р"
                default: "1"
                }
            }
        )
    }

    private func complete(_ text: String, with coordinator: ManualConversionCoordinator, in environment: InputSessionEnvironment) {
        for (offset, character) in text.enumerated() {
            coordinator.receive(.text(.init(keyCode: UInt16(offset + 1)), output: String(character)), in: environment)
        }
        coordinator.receive(.text(.init(keyCode: 50), output: " "), in: environment)
    }

    /// Command recognition now lives in the single `ManualCommandRecognizer`
    /// layer, so triggering a command is just handing the coordinator the ready
    /// "command performed" signal.
    @discardableResult
    private func triggerDoubleLeftShift(on coordinator: ManualConversionCoordinator, in environment: InputSessionEnvironment) -> ManualConversionResult {
        coordinator.performCommand(in: environment)
    }
}

private final class RecordingFocusInspector: FocusInspector, @unchecked Sendable {
    private let inspection: FocusInspection
    private let postInsertionText: String
    private var calls = 0
    private(set) var requestedCounts: [Int] = []

    init(inspection: FocusInspection, postInsertionText: String) {
        self.inspection = inspection
        self.postInsertionText = postInsertionText
    }

    func replacementProof(beforeCursorCount: Int) -> ReplacementProof {
        requestedCounts.append(beforeCursorCount)
        calls += 1
        var result = inspection
        result.localTextBeforeCursor = calls == 1 ? inspection.localTextBeforeCursor : postInsertionText
        return .exact(result)
    }
}

private final class OpaqueManualFocusInspector: FocusInspector, @unchecked Sendable {
    func replacementProof(beforeCursorCount: Int) -> ReplacementProof { .opaque }
}

private final class RecordingTextInjector: TextInjector, @unchecked Sendable {
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

/// Serves successive fields whose read-back text is sliced by the requested
/// UTF-16 count, so a caller that mistakenly requested grapheme lengths would be
/// caught by the range/text mismatch.
private final class UTF16FieldFocusInspector: FocusInspector, @unchecked Sendable {
    private var fields: [String]
    private(set) var requestedCounts: [Int] = []

    init(fields: [String]) {
        self.fields = fields
    }

    func replacementProof(beforeCursorCount: Int) -> ReplacementProof {
        requestedCounts.append(beforeCursorCount)
        guard !fields.isEmpty else { return .unavailable }
        let field = fields.removeFirst()
        // The AX API returns exactly the requested UTF-16 range. If the caller
        // asked for the wrong number of code units, the substring differs from
        // the full field and the exact proof fails closed.
        let units = Array(field.utf16)
        guard beforeCursorCount >= 0, beforeCursorCount <= units.count else { return .unavailable }
        let slice = String(decoding: units.suffix(beforeCursorCount), as: UTF16.self)
        return .exact(.init(
            processID: 42,
            elementID: "body",
            role: .textArea,
            isProtected: false,
            selection: .init(location: beforeCursorCount, length: 0),
            localTextBeforeCursor: slice
        ))
    }
}

private final class SequenceFocusInspector: FocusInspector, @unchecked Sendable {
    private var texts: [String]
    private(set) var requestedCounts: [Int] = []

    init(texts: [String]) {
        self.texts = texts
    }

    func replacementProof(beforeCursorCount: Int) -> ReplacementProof {
        requestedCounts.append(beforeCursorCount)
        guard !texts.isEmpty else { return .unavailable }
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

private final class RecordingInputSourceService: InputSourceService, @unchecked Sendable {
    private(set) var selectedLayoutIDs: [String] = []

    func selectInputSource(id: String) -> Bool {
        selectedLayoutIDs.append(id)
        return true
    }
}
