/// Immutable settings supplied by the system boundary for one input event.
public struct InputSessionConfiguration: Sendable, Equatable {
    public let revision: UInt64
    public let isAutomationEnabled: Bool
    public let wordExceptions: Set<String>

    /// Compatibility initializer for the former single automation flag.
    public init(revision: UInt64, isEnabled: Bool) {
        self.revision = revision
        isAutomationEnabled = isEnabled
        wordExceptions = []
    }

    public init(revision: UInt64, isAutomationEnabled: Bool, wordExceptions: Set<String> = []) {
        self.revision = revision
        self.isAutomationEnabled = isAutomationEnabled
        self.wordExceptions = Set(wordExceptions.compactMap(normalizedWordException))
    }

    public init(settings: AutomationSettings) {
        self.init(
            revision: settings.revision,
            isAutomationEnabled: settings.isAutomationEnabled,
            wordExceptions: settings.wordExceptions
        )
    }

    public func excludesFromAutomation(_ word: String) -> Bool {
        normalizedWordException(word).map(wordExceptions.contains) ?? false
    }
}

/// Identity and safety of the currently focused element, supplied by the system boundary.
public struct InputFocusSnapshot: Sendable, Equatable {
    public let applicationID: String
    public let elementID: String
    public let processID: Int32
    public let isSupported: Bool

    public init(applicationID: String, elementID: String, processID: Int32 = 0, isSupported: Bool) {
        self.applicationID = applicationID
        self.elementID = elementID
        self.processID = processID
        self.isSupported = isSupported
    }
}

/// Policy result supplied by the system boundary for the focused application.
public struct InputPolicySnapshot: Sendable, Equatable {
    public let allowsAutomaticCorrection: Bool
    public let allowsManualConversion: Bool
    public let revision: UInt64

    /// Tracking exists to support the remaining manual capability.
    public var allowsTracking: Bool { allowsManualConversion }

    /// Compatibility initializer for environments which allow both capabilities.
    public init(allowsTracking: Bool) {
        allowsAutomaticCorrection = allowsTracking
        allowsManualConversion = allowsTracking
        revision = 0
    }

    public init(
        allowsAutomaticCorrection: Bool,
        allowsManualConversion: Bool,
        revision: UInt64 = 0
    ) {
        self.allowsAutomaticCorrection = allowsAutomaticCorrection
        self.allowsManualConversion = allowsManualConversion
        self.revision = revision
    }
}

/// The selected pair and active layout supplied by the system boundary.
public struct InputLayoutSnapshot: Sendable, Equatable {
    public let pair: LayoutPair?
    public let availableLayoutIDs: Set<String>
    public let activeLayoutID: String

    public init(pair: LayoutPair?, availableLayoutIDs: Set<String>, activeLayoutID: String) {
        self.pair = pair
        self.availableLayoutIDs = availableLayoutIDs
        self.activeLayoutID = activeLayoutID
    }

    var candidateLayout: KeyboardLayout? {
        guard let pair, availableLayoutIDs.contains(pair.english.id), availableLayoutIDs.contains(pair.russian.id) else {
            return nil
        }
        switch activeLayoutID {
        case pair.english.id: return pair.russian
        case pair.russian.id: return pair.english
        default: return nil
        }
    }
}

/// The only environment input accepted by the active input session.
public struct InputSessionEnvironment: Sendable, Equatable {
    public let configuration: InputSessionConfiguration
    public let focus: InputFocusSnapshot
    public let policy: InputPolicySnapshot
    public let layouts: InputLayoutSnapshot

    public init(
        configuration: InputSessionConfiguration,
        focus: InputFocusSnapshot,
        policy: InputPolicySnapshot,
        layouts: InputLayoutSnapshot
    ) {
        self.configuration = configuration
        self.focus = focus
        self.policy = policy
        self.layouts = layouts
    }

    var isTrackable: Bool {
        focus.isSupported && policy.allowsManualConversion && layouts.candidateLayout != nil
    }
}

/// A normalized key event whose output was read by the platform boundary.
public enum InputSessionEvent: Sendable, Equatable {
    case text(KeyStroke, output: String)
    case shiftDown(ShiftSide, milliseconds: UInt64)
    case shiftUp(ShiftSide, milliseconds: UInt64)
    case manualCommand
    case returnKey
    case enterKey
    case tab
    case escape
    case commandCombination
    case optionCombination
    case deadKey
    case navigation
    case selection
    case paste
    case forwardDelete
    case mouseClick
    case backspace
    case inputLost
}

public enum InputSessionBreakReason: Sendable, Equatable {
    case returnKey
    case enterKey
    case tab
    case escape
    case commandCombination
    case optionCombination
    case deadKey
    case navigation
    case selection
    case paste
    case forwardDelete
    case mouseClick
    case backspace
    case inputLost
    case invalidTextOutput
    case environmentChanged
}

/// This ticket intentionally exposes no command that can change text.
public enum InputSessionCommand: Sendable, Equatable {
    case breakSession(InputSessionBreakReason)
}

/// A tracked sequence of physical keys and the candidate made from those same keys.
public struct InputSessionToken: Sendable, Equatable {
    public let typed: String
    public let candidate: String?
    public let keyCount: Int
    public let isTechnical: Bool
    public let isWithinLimit: Bool

    public init(typed: String, candidate: String?, keyCount: Int, isTechnical: Bool, isWithinLimit: Bool) {
        self.typed = typed
        self.candidate = candidate
        self.keyCount = keyCount
        self.isTechnical = isTechnical
        self.isWithinLimit = isWithinLimit
    }
}

public enum ActiveInputSessionState: Sendable, Equatable {
    case idle
    case tracking(InputSessionToken)
    case lastCompleted(InputSessionToken)
}

public struct InputSessionReduction: Sendable, Equatable {
    public let state: ActiveInputSessionState
    public let commands: [InputSessionCommand]
}

/// Deterministically tracks one linear input session without reading or changing text.
public struct InputSessionReducer {
    public typealias Translate = (KeyboardLayout, KeyStroke) -> String?

    private static let maximumKeyCount = 64
    private let translate: Translate
    private var storage: Storage = .idle

    public init(translate: @escaping Translate) {
        self.translate = translate
    }

    @discardableResult
    public mutating func reduce(
        _ event: InputSessionEvent,
        in environment: InputSessionEnvironment
    ) -> InputSessionReduction {
        if let reason = breakReason(for: event) {
            return breakSession(reason)
        }

        guard environment.isTrackable else {
            return storage.isActive ? breakSession(.environmentChanged) : reduction()
        }
        if let fingerprint = storage.fingerprint, fingerprint != Fingerprint(environment) {
            return breakSession(.environmentChanged)
        }

        switch event {
        case let .text(stroke, output):
            return receive(stroke: stroke, output: output, environment: environment)
        case .backspace:
            return backspace()
        default:
            return reduction()
        }
    }

    private mutating func receive(
        stroke: KeyStroke,
        output: String,
        environment: InputSessionEnvironment
    ) -> InputSessionReduction {
        guard output.count == 1, let character = output.first else {
            return breakSession(.invalidTextOutput)
        }

        let candidate = environment.layouts.candidateLayout.flatMap { translate($0, stroke) }
        let candidateIsLetter = candidate?.count == 1 && candidate?.first?.isLetter == true
        if character.isLetter || (!character.isWhitespace && !isTechnical(character) && candidateIsLetter) {
            let part = Part(
                typed: character,
                candidate: candidate
            )
            switch storage {
            case .tracking(let fingerprint, var parts):
                parts.append(part)
                storage = .tracking(fingerprint, parts)
            case .idle, .lastCompleted:
                storage = .tracking(Fingerprint(environment), [part])
            }
            return reduction()
        }

        if character == "-" || character == "'" || character == "’" {
            return appendConnector(stroke: stroke, character: character, environment: environment)
        }

        if isTechnical(character) {
            let part = Part(
                typed: character,
                candidate: environment.layouts.candidateLayout.flatMap { translate($0, stroke) }
            )
            switch storage {
            case .tracking(let fingerprint, var parts):
                parts.append(part)
                storage = .tracking(fingerprint, parts)
            case .idle, .lastCompleted:
                storage = .tracking(Fingerprint(environment), [part])
            }
            return reduction()
        }

        finishWord()
        return reduction()
    }

    private mutating func appendConnector(
        stroke: KeyStroke,
        character: Character,
        environment: InputSessionEnvironment
    ) -> InputSessionReduction {
        guard case let .tracking(fingerprint, parts) = storage, !parts.isEmpty else {
            return reduction()
        }
        var updated = parts
        updated.append(Part(
            typed: character,
            candidate: environment.layouts.candidateLayout.flatMap { translate($0, stroke) }
        ))
        storage = .tracking(fingerprint, updated)
        return reduction()
    }

    private mutating func backspace() -> InputSessionReduction {
        guard case let .tracking(fingerprint, parts) = storage else {
            return breakSession(.backspace)
        }
        guard !parts.isEmpty else {
            return breakSession(.backspace)
        }
        storage = .tracking(fingerprint, Array(parts.dropLast()))
        return reduction()
    }

    private mutating func finishWord() {
        guard case let .tracking(fingerprint, parts) = storage, let token = token(from: parts) else {
            storage = .idle
            return
        }
        storage = token.isWithinLimit ? .lastCompleted(fingerprint, token) : .idle
    }

    private mutating func breakSession(_ reason: InputSessionBreakReason) -> InputSessionReduction {
        storage = .idle
        return reduction(commands: [.breakSession(reason)])
    }

    private func breakReason(for event: InputSessionEvent) -> InputSessionBreakReason? {
        switch event {
        case .returnKey: .returnKey
        case .enterKey: .enterKey
        case .tab: .tab
        case .escape: .escape
        case .commandCombination: .commandCombination
        case .optionCombination: .optionCombination
        case .deadKey: .deadKey
        case .navigation: .navigation
        case .selection: .selection
        case .paste: .paste
        case .forwardDelete: .forwardDelete
        case .mouseClick: .mouseClick
        case .inputLost: .inputLost
        case .text, .shiftDown, .shiftUp, .manualCommand, .backspace: nil
        }
    }

    private func reduction(commands: [InputSessionCommand] = []) -> InputSessionReduction {
        InputSessionReduction(state: state, commands: commands)
    }

    private var state: ActiveInputSessionState {
        switch storage {
        case .idle:
            .idle
        case let .tracking(_, parts):
            token(from: parts).map(ActiveInputSessionState.tracking) ?? .idle
        case let .lastCompleted(_, token):
            .lastCompleted(token)
        }
    }

    private func token(from parts: [Part]) -> InputSessionToken? {
        guard !parts.isEmpty else { return nil }
        let hasTechnicalPart = parts.contains { isTechnical($0.typed) }
        if hasTechnicalPart {
            return makeToken(parts, technical: true)
        }

        let wordParts = Array(parts.prefix { isLetterLike($0) || isConnector($0.typed) })
        guard !wordParts.isEmpty else { return nil }
        let validEnd = wordParts.lastIndex(where: isLetterLike)
        guard let validEnd else { return nil }
        let trimmed = Array(wordParts[...validEnd])
        guard trimmed.indices.allSatisfy({ index in
            let part = trimmed[index]
            return isLetterLike(part) || (
                isConnector(part.typed) &&
                index > trimmed.startIndex && index < trimmed.endIndex - 1 &&
                isLetterLike(trimmed[trimmed.index(before: index)]) &&
                isLetterLike(trimmed[trimmed.index(after: index)])
            )
        }) else {
            return makeToken(parts, technical: true)
        }
        return makeToken(trimmed, technical: false)
    }

    private func makeToken(_ parts: [Part], technical: Bool) -> InputSessionToken {
        let candidate = parts.allSatisfy { $0.candidate?.count == 1 }
            ? parts.compactMap(\.candidate).joined()
            : nil
        return InputSessionToken(
            typed: String(parts.map(\.typed)),
            candidate: candidate,
            keyCount: parts.count,
            isTechnical: technical,
            isWithinLimit: parts.count <= Self.maximumKeyCount
        )
    }

    private func isTechnical(_ character: Character) -> Bool {
        TechnicalToken.isTechnical(character)
    }

    private func isLetterLike(_ part: Part) -> Bool {
        part.typed.isLetter || (part.candidate?.count == 1 && part.candidate?.first?.isLetter == true)
    }

    private func isConnector(_ character: Character) -> Bool {
        character == "-" || character == "'" || character == "’"
    }
}

private struct Fingerprint: Equatable, Sendable {
    let configurationRevision: UInt64
    let policyRevision: UInt64
    let allowsManualConversion: Bool
    let applicationID: String
    let elementID: String
    let processID: Int32
    let pair: LayoutPair?
    let activeLayoutID: String

    init(_ environment: InputSessionEnvironment) {
        configurationRevision = environment.configuration.revision
        policyRevision = environment.policy.revision
        allowsManualConversion = environment.policy.allowsManualConversion
        applicationID = environment.focus.applicationID
        elementID = environment.focus.elementID
        processID = environment.focus.processID
        pair = environment.layouts.pair
        activeLayoutID = environment.layouts.activeLayoutID
    }
}

private struct Part: Sendable {
    let typed: Character
    let candidate: String?
}

private enum Storage: Sendable {
    case idle
    case tracking(Fingerprint, [Part])
    case lastCompleted(Fingerprint, InputSessionToken)

    var isActive: Bool {
        if case .idle = self { false } else { true }
    }

    var fingerprint: Fingerprint? {
        switch self {
        case .idle: nil
        case let .tracking(fingerprint, _), let .lastCompleted(fingerprint, _): fingerprint
        }
    }
}
