import XCTest
@testable import SwitcherCore

final class ActiveInputSessionTests: XCTestCase {
    private let english = KeyboardLayout(id: "english", name: "English")
    private let russian = KeyboardLayout(id: "russian", name: "Russian")

    func testTracksWordsAndCandidatesUsingPhysicalModifiersThenCompletesOnSpace() {
        var reducer = InputSessionReducer(translate: translate)
        let environment = environment()

        reducer.reduce(.text(.init(keyCode: 1), output: "g"), in: environment)
        reducer.reduce(.text(.init(keyCode: 2, modifiers: [.shift]), output: "H"), in: environment)
        reducer.reduce(.text(.init(keyCode: 3), output: "-"), in: environment)
        reducer.reduce(.text(.init(keyCode: 4, modifiers: [.capsLock]), output: "b"), in: environment)
        let completed = reducer.reduce(.text(.init(keyCode: 5), output: " "), in: environment)

        XCTAssertEqual(completed.commands, [])
        XCTAssertEqual(completed.state, .lastCompleted(.init(
            typed: "gH-b",
            candidate: "пР-и",
            keyCount: 4,
            isTechnical: false,
            isWithinLimit: true
        )))
    }

    func testTechnicalTokensRemainAvailableOnlyForManualConversionWhileOverlongInputIsNot() {
        var technicalReducer = InputSessionReducer(translate: translate)
        let environment = environment()

        technicalReducer.reduce(.text(.init(keyCode: 1), output: "g"), in: environment)
        technicalReducer.reduce(.text(.init(keyCode: 6), output: "1"), in: environment)
        let technical = technicalReducer.reduce(.text(.init(keyCode: 5), output: " "), in: environment)
        XCTAssertEqual(technical.state, .lastCompleted(.init(
            typed: "g1",
            candidate: "пя",
            keyCount: 2,
            isTechnical: true,
            isWithinLimit: true
        )))

        var addressReducer = InputSessionReducer(translate: translate)
        addressReducer.reduce(.text(.init(keyCode: 1), output: "g"), in: environment)
        addressReducer.reduce(.text(.init(keyCode: 7), output: "@"), in: environment)
        addressReducer.reduce(.text(.init(keyCode: 2), output: "h"), in: environment)
        XCTAssertEqual(addressReducer.reduce(.text(.init(keyCode: 5), output: " "), in: environment).state, .lastCompleted(.init(
            typed: "g@h",
            candidate: "пяя",
            keyCount: 3,
            isTechnical: true,
            isWithinLimit: true
        )))

        var longReducer = InputSessionReducer(translate: translate)
        for _ in 0 ..< 65 {
            longReducer.reduce(.text(.init(keyCode: 1), output: "g"), in: environment)
        }
        let long = longReducer.reduce(.text(.init(keyCode: 5), output: " "), in: environment)
        XCTAssertEqual(long.state, .idle)
    }

    func testPunctuationCompletesAnOrdinaryWord() {
        var reducer = InputSessionReducer(translate: translate)
        let environment = environment()

        reducer.reduce(.text(.init(keyCode: 1), output: "g"), in: environment)
        let result = reducer.reduce(.text(.init(keyCode: 8), output: "."), in: environment)

        XCTAssertEqual(result.state, .lastCompleted(.init(
            typed: "g", candidate: "п", keyCount: 1, isTechnical: false, isWithinLimit: true
        )))
    }

    func testTracksAPunctuationKeyWhenThePairedLayoutProducesALetter() {
        var reducer = InputSessionReducer(translate: { layout, stroke in
            switch (layout.id, stroke.keyCode) {
            case ("russian", 9): "б"
            case ("russian", 10): "ы"
            default: nil
            }
        })
        let environment = environment()

        reducer.reduce(.text(.init(keyCode: 9), output: ","), in: environment)
        reducer.reduce(.text(.init(keyCode: 10), output: "s"), in: environment)
        let completed = reducer.reduce(.text(.init(keyCode: 5), output: " "), in: environment)

        XCTAssertEqual(completed.state, .lastCompleted(.init(
            typed: ",s", candidate: "бы", keyCount: 2, isTechnical: false, isWithinLimit: true
        )))
    }

    func testBreakEventsEndTheSessionWithoutTextCommands() {
        let breakEvents: [(InputSessionEvent, InputSessionBreakReason)] = [
            (.returnKey, .returnKey), (.enterKey, .enterKey), (.tab, .tab), (.escape, .escape),
            (.commandCombination, .commandCombination), (.optionCombination, .optionCombination),
            (.deadKey, .deadKey), (.navigation, .navigation), (.selection, .selection),
            (.paste, .paste), (.forwardDelete, .forwardDelete), (.mouseClick, .mouseClick),
            (.inputLost, .inputLost),
        ]
        let environment = environment()

        for (event, reason) in breakEvents {
            var reducer = InputSessionReducer(translate: translate)
            reducer.reduce(.text(.init(keyCode: 1), output: "g"), in: environment)
            let result = reducer.reduce(event, in: environment)

            XCTAssertEqual(result.state, .idle)
            XCTAssertEqual(result.commands, [.breakSession(reason)])
        }
    }

    func testBackspaceLeftOfTheTrackedWordBreaksTheSession() {
        var reducer = InputSessionReducer(translate: translate)
        let environment = environment()

        reducer.reduce(.text(.init(keyCode: 1), output: "g"), in: environment)
        XCTAssertEqual(reducer.reduce(.backspace, in: environment).state, .idle)
        let result = reducer.reduce(.backspace, in: environment)

        XCTAssertEqual(result.commands, [.breakSession(.backspace)])
    }

    func testAppFocusOrLayoutChangeBreaksAnActiveSession() {
        let initial = environment()
        let changedEnvironments = [
            environment(app: "other"),
            environment(element: "other-field"),
            environment(activeLayoutID: russian.id),
        ]

        for changed in changedEnvironments {
            var reducer = InputSessionReducer(translate: translate)
            reducer.reduce(.text(.init(keyCode: 1), output: "g"), in: initial)
            let result = reducer.reduce(.text(.init(keyCode: 2), output: "h"), in: changed)

            XCTAssertEqual(result.state, .idle)
            XCTAssertEqual(result.commands, [.breakSession(.environmentChanged)])
        }
    }

    private func environment(
        app: String = "TextEdit",
        element: String = "body",
        activeLayoutID: String? = nil
    ) -> InputSessionEnvironment {
        .init(
            configuration: .init(revision: 1, isEnabled: true),
            focus: .init(applicationID: app, elementID: element, isSupported: true),
            policy: .init(allowsTracking: true),
            layouts: .init(
                pair: .init(english: english, russian: russian),
                availableLayoutIDs: [english.id, russian.id],
                activeLayoutID: activeLayoutID ?? english.id
            )
        )
    }

    private func translate(_ layout: KeyboardLayout, _ stroke: KeyStroke) -> String? {
        switch (layout.id, stroke.keyCode, stroke.modifiers) {
        case ("russian", 1, []): "п"
        case ("russian", 2, [.shift]): "Р"
        case ("russian", 3, []): "-"
        case ("russian", 4, [.capsLock]): "и"
        case ("russian", 8, _): nil
        default: "я"
        }
    }
}
