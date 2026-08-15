import Foundation

/// A physical Shift key, kept distinct so two different Shift keys cannot form a command.
public enum ShiftSide: Sendable, Equatable {
    case left
    case right
}

/// The minimal local Accessibility proof required before modifying a focused field.
public struct FocusInspection: Sendable, Equatable {
    public enum Role: Sendable, Equatable {
        case textField
        case textArea
        case unsupported
    }

    public struct Selection: Sendable, Equatable {
        public let location: Int
        public let length: Int

        public init(location: Int, length: Int) {
            self.location = location
            self.length = length
        }
    }

    public let processID: Int32
    public let elementID: String
    public let role: Role
    public let isEditable: Bool
    public let isProtected: Bool
    public let selection: Selection
    public var localTextBeforeCursor: String?

    public init(
        processID: Int32,
        elementID: String,
        role: Role,
        isEditable: Bool = true,
        isProtected: Bool,
        selection: Selection,
        localTextBeforeCursor: String?
    ) {
        self.processID = processID
        self.elementID = elementID
        self.role = role
        self.isEditable = isEditable
        self.isProtected = isProtected
        self.selection = selection
        self.localTextBeforeCursor = localTextBeforeCursor
    }
}

/// The two proofs that can authorize automatic replacement.
public enum ReplacementProof: Sendable, Equatable {
    /// The focused field exposed the exact short AX range requested by the app.
    case exact(FocusInspection)
    /// A non-secure editable field stayed continuously observed but exposes no local AX range.
    case opaque
    /// Neither proof is available, so replacement must not begin.
    case unavailable
}

/// Reads only the requested short range immediately before the cursor. It never reads field contents.
///
/// `beforeCursorCount` is expressed in **UTF-16 code units**, matching the units
/// used by the Accessibility range APIs (`kAXSelectedTextRange`,
/// `kAXStringForRange`). Callers must convert grapheme-based lengths with
/// `String.utf16.count` before requesting a proof so composite Unicode in the
/// suffix cannot desynchronize the requested range from the read-back text.
public protocol FocusInspector: Sendable {
    func replacementProof(beforeCursorCount: Int) -> ReplacementProof
}

/// Posts application-marked deletion and Unicode input events. It has no clipboard or AX-write operation.
public protocol TextInjector: Sendable {
    func sendMarkedBackspaces(_ count: Int) -> Bool
    func sendMarkedUnicode(_ text: String) -> Bool
}

/// Selects the input source after a replacement has been re-verified.
public protocol InputSourceService: Sendable {
    func selectInputSource(id: String) -> Bool
}

public enum ManualConversionResult: Sendable, Equatable {
    case ignored
    case rejected
    case injectionFailed
    case postVerificationFailed
    case layoutSelectionFailed
    case replaced
}

public enum ManualConversionAvailability: Sendable, Equatable {
    case available
    case disabledAfterFailure
}

/// Coordinates the manual shortcut with verified or continuously observed input.
public final class ManualConversionCoordinator: @unchecked Sendable {
    private static let maximumSuffixLength = 16
    private static let postVerificationAttempts = 20

    private let focusInspector: FocusInspector
    private let textInjector: TextInjector
    private let inputSourceService: InputSourceService
    private let translate: InputSessionReducer.Translate
    private var session: InputSessionReducer
    private var isClosedAfterCommand = false
    private var trailingSuffix = ""
    private var replacement: ReversibleReplacement?
    public private(set) var availability: ManualConversionAvailability = .available

    public init(
        focusInspector: FocusInspector,
        textInjector: TextInjector,
        inputSourceService: InputSourceService,
        translate: @escaping InputSessionReducer.Translate
    ) {
        self.focusInspector = focusInspector
        self.textInjector = textInjector
        self.inputSourceService = inputSourceService
        self.translate = translate
        session = InputSessionReducer(translate: translate)
    }

    /// Drops all unverified input knowledge after an unreliable event stream.
    public func closeSession() {
        trailingSuffix = ""
        replacement = nil
        isClosedAfterCommand = true
        session = InputSessionReducer(translate: translate)
    }

    /// Tracks a physical event without ever recognizing the command itself.
    ///
    /// Command recognition (Double Shift / custom shortcut) now lives in one
    /// runtime-wide layer; this coordinator only keeps its input model and
    /// suffix/replacement bookkeeping up to date and waits for the dispatcher
    /// to call `performCommand(in:)`.
    @discardableResult
    public func receive(
        _ event: InputSessionEvent,
        in environment: InputSessionEnvironment
    ) -> ManualConversionResult {
        guard availability == .available else { return .ignored }
        let reduction = session.reduce(event, in: environment)
        if case .text = event { isClosedAfterCommand = false }

        updateTrailingSuffix(for: event, reduction: reduction)
        updateReplacement(for: event, reduction: reduction, in: environment)
        return .ignored
    }

    /// Applies a recognized manual command against the currently tracked word.
    @discardableResult
    public func performCommand(in environment: InputSessionEnvironment) -> ManualConversionResult {
        guard availability == .available else { return .ignored }
        guard !isClosedAfterCommand else { return .ignored }
        let reduction = session.reduce(.manualCommand, in: environment)
        if let replacement {
            // A replacement that no longer matches the current environment can
            // no longer be trusted; drop it rather than toggle stale text.
            guard replacement.matches(environment) else {
                self.replacement = nil
                return .ignored
            }
            return toggle(replacement, in: environment)
        }
        guard
            let token = token(from: reduction.state),
            token.isWithinLimit,
            let candidate = token.candidate,
            let target = environment.layouts.candidateLayout
        else { return .ignored }

        let expected = token.typed + trailingSuffix
        guard let proof = preflight(expected, in: environment) else {
            return fail(.rejected)
        }
        guard
            textInjector.sendMarkedBackspaces(expected.count),
            textInjector.sendMarkedUnicode(candidate),
            trailingSuffix.isEmpty || textInjector.sendMarkedUnicode(trailingSuffix)
        else {
            return fail(.injectionFailed)
        }
        guard postflight(candidate + trailingSuffix, proof: proof, in: environment) else {
            return fail(.postVerificationFailed)
        }
        guard inputSourceService.selectInputSource(id: target.id) else {
            return fail(.layoutSelectionFailed)
        }
        replacement = .init(
            original: token.typed,
            candidate: candidate,
            sourceLayoutID: environment.layouts.activeLayoutID,
            candidateLayoutID: target.id,
            suffix: trailingSuffix,
            environment: environment
        )
        trailingSuffix = ""
        session = InputSessionReducer(translate: translate)
        return .replaced
    }

    private func preflight(_ expected: String, in environment: InputSessionEnvironment) -> ReplacementProof? {
        guard environment.focus.isSupported else { return nil }
        // AX ranges are indexed in UTF-16 code units, so the requested length
        // must be measured the same way; backspace counts remain in graphemes.
        switch focusInspector.replacementProof(beforeCursorCount: expected.utf16.count) {
        case let .exact(inspection) where isExact(inspection, expected: expected, in: environment):
            return .exact(inspection)
        case .opaque:
            return .opaque
        case .exact, .unavailable:
            return nil
        }
    }

    /// Re-verifies the exact AX range after injection.  The poll stays on the
    /// caller's turn but never blocks it: instead of a `Thread.sleep` retry
    /// loop it re-reads the short range immediately, so a busy field cannot
    /// freeze the event loop.  Exhausting the attempts fails closed.
    private func postflight(_ expected: String, proof: ReplacementProof, in environment: InputSessionEnvironment) -> Bool {
        guard case .exact = proof else { return true }
        for _ in 0 ..< Self.postVerificationAttempts {
            guard case let .exact(inspection) = focusInspector.replacementProof(beforeCursorCount: expected.utf16.count) else {
                continue
            }
            if isExact(inspection, expected: expected, in: environment) { return true }
        }
        return false
    }

    private func isExact(_ inspection: FocusInspection, expected: String, in environment: InputSessionEnvironment) -> Bool {
        inspection.processID == environment.focus.processID &&
            inspection.elementID == environment.focus.elementID &&
            (inspection.role == .textField || inspection.role == .textArea) &&
            inspection.isEditable &&
            !inspection.isProtected &&
            inspection.selection.length == 0 &&
            inspection.localTextBeforeCursor == expected
    }

    private func token(from state: ActiveInputSessionState) -> InputSessionToken? {
        switch state {
        case let .tracking(token), let .lastCompleted(token): token
        case .idle: nil
        }
    }

    /// Any injection, verification, or layout-selection failure closes the
    /// session and latches the runtime into its recovery state; it performs no
    /// rollback of partially changed text.
    private func fail(_ result: ManualConversionResult) -> ManualConversionResult {
        closeSession()
        availability = .disabledAfterFailure
        return result
    }

    private func updateTrailingSuffix(for event: InputSessionEvent, reduction: InputSessionReduction) {
        guard replacement == nil else { return }
        guard reduction.commands.isEmpty else {
            trailingSuffix = ""
            return
        }
        guard case .lastCompleted = reduction.state else {
            if case .text = event { trailingSuffix = "" }
            return
        }
        guard let character = suffixCharacter(from: event) else { return }
        guard trailingSuffix.count < Self.maximumSuffixLength else {
            trailingSuffix = ""
            session = InputSessionReducer(translate: translate)
            return
        }
        trailingSuffix.append(character)
    }

    private func updateReplacement(
        for event: InputSessionEvent,
        reduction: InputSessionReduction,
        in environment: InputSessionEnvironment
    ) {
        guard var replacement else { return }
        guard replacement.matches(environment) else {
            self.replacement = nil
            return
        }
        guard reduction.commands.isEmpty else {
            self.replacement = nil
            return
        }
        guard let character = suffixCharacter(from: event) else {
            // Editing content after a replacement means the tracked word can no
            // longer be trusted; drop the whole session rather than leave a
            // stale token that a later command could convert.
            if case .text = event { closeSession() }
            return
        }
        guard replacement.suffix.count < Self.maximumSuffixLength else {
            self.replacement = nil
            return
        }
        replacement.suffix.append(character)
        self.replacement = replacement
    }

    private func suffixCharacter(from event: InputSessionEvent) -> Character? {
        guard case let .text(_, output) = event, output.count == 1, let character = output.first,
              character == " " || character.isPunctuation else { return nil }
        return character
    }

    private func toggle(
        _ replacement: ReversibleReplacement,
        in environment: InputSessionEnvironment
    ) -> ManualConversionResult {
        let expected = replacement.displayed + replacement.suffix
        guard let proof = preflight(expected, in: environment) else {
            return fail(.rejected)
        }

        let next = replacement.toggled()
        guard
            textInjector.sendMarkedBackspaces(expected.count),
            textInjector.sendMarkedUnicode(next.displayed),
            next.suffix.isEmpty || textInjector.sendMarkedUnicode(next.suffix)
        else {
            return fail(.injectionFailed)
        }
        guard postflight(next.displayed + next.suffix, proof: proof, in: environment) else {
            return fail(.postVerificationFailed)
        }
        guard inputSourceService.selectInputSource(id: next.displayedLayoutID) else {
            return fail(.layoutSelectionFailed)
        }
        self.replacement = next
        session = InputSessionReducer(translate: translate)
        return .replaced
    }
}

private struct ReversibleReplacement {
    let original: String
    let candidate: String
    let sourceLayoutID: String
    let candidateLayoutID: String
    let configurationRevision: UInt64
    let policyRevision: UInt64
    let applicationID: String
    let elementID: String
    let processID: Int32
    let englishLayoutID: String
    let russianLayoutID: String
    var isShowingCandidate = true
    var suffix: String

    init(
        original: String,
        candidate: String,
        sourceLayoutID: String,
        candidateLayoutID: String,
        suffix: String,
        environment: InputSessionEnvironment
    ) {
        self.original = original
        self.candidate = candidate
        self.sourceLayoutID = sourceLayoutID
        self.candidateLayoutID = candidateLayoutID
        self.suffix = suffix
        configurationRevision = environment.configuration.revision
        policyRevision = environment.policy.revision
        applicationID = environment.focus.applicationID
        elementID = environment.focus.elementID
        processID = environment.focus.processID
        englishLayoutID = environment.layouts.pair?.english.id ?? ""
        russianLayoutID = environment.layouts.pair?.russian.id ?? ""
    }

    var displayed: String { isShowingCandidate ? candidate : original }
    var displayedLayoutID: String { isShowingCandidate ? candidateLayoutID : sourceLayoutID }

    func toggled() -> Self {
        var replacement = self
        replacement.isShowingCandidate.toggle()
        return replacement
    }

    func matches(_ environment: InputSessionEnvironment) -> Bool {
        guard
            environment.configuration.revision == configurationRevision,
            environment.policy.revision == policyRevision,
            environment.focus.isSupported,
            environment.policy.allowsManualConversion,
            environment.focus.applicationID == applicationID,
            environment.focus.elementID == elementID,
            environment.focus.processID == processID,
            environment.layouts.activeLayoutID == displayedLayoutID,
            environment.layouts.availableLayoutIDs.isSuperset(of: [sourceLayoutID, candidateLayoutID]),
            environment.layouts.pair?.english.id == englishLayoutID,
            environment.layouts.pair?.russian.id == russianLayoutID
        else { return false }
        return true
    }
}

private struct FocusIdentity {
    let applicationID: String
    let elementID: String
    let processID: Int32

    init(_ environment: InputSessionEnvironment) {
        applicationID = environment.focus.applicationID
        elementID = environment.focus.elementID
        processID = environment.focus.processID
    }

    func matches(_ environment: InputSessionEnvironment) -> Bool {
        applicationID == environment.focus.applicationID &&
            elementID == environment.focus.elementID &&
            processID == environment.focus.processID
    }
}
