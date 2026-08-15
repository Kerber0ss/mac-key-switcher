import Foundation

/// Observable result of receiving a physical input event or running a pending correction.
public enum AutomaticCorrectionResult: Sendable, Equatable {
    case ignored
    case pending
    case cancelled
    case rejected
    case injectionFailed
    case postVerificationFailed
    case layoutSelectionFailed
    case replaced
}

/// The observable automatic-correction gate; manual conversion has its own coordinator.
public enum AutomaticCorrectionAvailability: Sendable, Equatable {
    case available
    case disabledAfterFailure
}

/// Safely applies only detector-approved corrections after their separator has reached the field.
public final class AutomaticCorrectionCoordinator: @unchecked Sendable {
    private static let maximumSuffixLength = 16
    private static let postVerificationAttempts = 20

    private let focusInspector: FocusInspector
    private let textInjector: TextInjector
    private let inputSourceService: InputSourceService
    private let detector: LanguageDetector
    private let translate: InputSessionReducer.Translate
    private var session: InputSessionReducer
    private var pending: PendingCorrection?
    private var replacement: AutomaticReversibleReplacement?
    private var isClosedAfterCommand = false
    public private(set) var availability: AutomaticCorrectionAvailability = .available

    public init(
        focusInspector: FocusInspector,
        textInjector: TextInjector,
        inputSourceService: InputSourceService,
        detector: LanguageDetector,
        translate: @escaping InputSessionReducer.Translate
    ) {
        self.focusInspector = focusInspector
        self.textInjector = textInjector
        self.inputSourceService = inputSourceService
        self.detector = detector
        self.translate = translate
        session = InputSessionReducer(translate: translate)
    }

    /// Drops all unverified input knowledge after an unreliable event stream.
    public func closeSession() {
        pending = nil
        replacement = nil
        session = InputSessionReducer(translate: translate)
        isClosedAfterCommand = true
    }

    @discardableResult
    public func receive(
        _ event: InputSessionEvent,
        in environment: InputSessionEnvironment
    ) -> AutomaticCorrectionResult {
        guard environment.policy.allowsAutomaticCorrection else {
            let wasPending = pending != nil
            pending = nil
            replacement = nil
            session = InputSessionReducer(translate: translate)
            return wasPending ? .cancelled : .ignored
        }
        guard availability == .available else { return .ignored }
        let cancelledPending = pending != nil
        pending = nil
        let reduction = session.reduce(event, in: environment)
        if case .text = event { isClosedAfterCommand = false }
        updateReplacement(for: event, reduction: reduction, in: environment)

        guard !cancelledPending else { return .cancelled }
        guard
            environment.configuration.isAutomationEnabled,
            isSeparator(event),
            case let .lastCompleted(token) = reduction.state,
            token.isWithinLimit,
            !token.isTechnical,
            !environment.configuration.excludesFromAutomation(token.typed),
            let candidate = token.candidate,
            let target = environment.layouts.candidateLayout
        else { return .ignored }

        guard detector.decide(word: token.typed, candidate: candidate).decision == .correct else {
            return .ignored
        }
        pending = .init(
            original: token.typed,
            candidate: candidate,
            suffix: separator(from: event),
            sourceLayoutID: environment.layouts.activeLayoutID,
            candidateLayoutID: target.id,
            environment: environment
        )
        return .pending
    }

    /// Applies a recognized manual command (Double Shift / custom shortcut).
    ///
    /// Recognition now lives in a single runtime-wide layer, so the coordinator
    /// is handed a ready "command performed" signal instead of watching Shift
    /// events itself.  For automatic correction the command only reverses an
    /// existing reversible replacement; if there is none it is ignored.
    @discardableResult
    public func performCommand(in environment: InputSessionEnvironment) -> AutomaticCorrectionResult {
        guard environment.policy.allowsAutomaticCorrection else { return .ignored }
        guard availability == .available else { return .ignored }
        // A replacement that no longer matches the current environment (layout,
        // settings/policy revision, focus) can no longer be trusted; drop it
        // rather than toggle stale text.
        guard let replacement, replacement.matches(environment) else {
            self.replacement = nil
            return .ignored
        }
        return toggle(replacement, in: environment)
    }

    /// Call after the event queue has yielded; any physical event received first cancels this work.
    @discardableResult
    public func performPendingCorrection(in environment: InputSessionEnvironment) -> AutomaticCorrectionResult {
        guard let pending, pending.matches(environment) else {
            self.pending = nil
            return .ignored
        }
        let expected = pending.original + pending.suffix
        guard let proof = preflight(expected, in: environment) else {
            self.pending = nil
            return fail(.rejected)
        }
        guard
            textInjector.sendMarkedBackspaces(expected.count),
            textInjector.sendMarkedUnicode(pending.candidate),
            pending.suffix.isEmpty || textInjector.sendMarkedUnicode(pending.suffix)
        else {
            return fail(.injectionFailed)
        }
        guard postflight(pending.candidate + pending.suffix, proof: proof, in: environment) else {
            return fail(.postVerificationFailed)
        }
        guard inputSourceService.selectInputSource(id: pending.candidateLayoutID) else {
            return fail(.layoutSelectionFailed)
        }
        replacement = .init(pending)
        self.pending = nil
        session = InputSessionReducer(translate: translate)
        return .replaced
    }

    /// Some applications do not expose their editor through Accessibility. In that case
    /// the replacement uses only immediately observed physical keys in the unchanged app.
    private func preflight(_ expected: String, in environment: InputSessionEnvironment) -> ReplacementProof? {
        guard environment.focus.isSupported else { return nil }
        // AX ranges (`selectedRange`/`kAXStringForRange`) are indexed in UTF-16
        // code units, so the requested length must be measured the same way.
        // Backspace counts stay in graphemes because a Delete key removes one
        // grapheme cluster; only the AX proof uses UTF-16.
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
    private func postflight(
        _ expected: String,
        proof: ReplacementProof,
        in environment: InputSessionEnvironment
    ) -> Bool {
        guard case .exact = proof else { return true }
        for _ in 0 ..< Self.postVerificationAttempts {
            guard case let .exact(inspection) = focusInspector.replacementProof(beforeCursorCount: expected.utf16.count) else {
                continue
            }
            if isExact(inspection, expected: expected, in: environment) { return true }
        }
        return false
    }

    private func isExact(
        _ inspection: FocusInspection,
        expected: String,
        in environment: InputSessionEnvironment
    ) -> Bool {
        inspection.processID == environment.focus.processID &&
            inspection.elementID == environment.focus.elementID &&
            (inspection.role == .textField || inspection.role == .textArea) &&
            inspection.isEditable &&
            !inspection.isProtected &&
            inspection.selection.length == 0 &&
            inspection.localTextBeforeCursor == expected
    }

    /// Any injection, verification, or layout-selection failure closes the
    /// session and latches the runtime into its recovery state; it performs no
    /// rollback of partially changed text.
    private func fail(_ result: AutomaticCorrectionResult) -> AutomaticCorrectionResult {
        closeSession()
        availability = .disabledAfterFailure
        return result
    }

    private func updateReplacement(
        for event: InputSessionEvent,
        reduction: InputSessionReduction,
        in environment: InputSessionEnvironment
    ) {
        guard var replacement else { return }
        guard replacement.matches(environment), reduction.commands.isEmpty else {
            self.replacement = nil
            return
        }
        guard let character = separator(from: event) else {
            if case .text = event { self.replacement = nil }
            return
        }
        guard replacement.suffix.count < Self.maximumSuffixLength else {
            self.replacement = nil
            return
        }
        replacement.suffix.append(character)
        self.replacement = replacement
    }

    private func toggle(
        _ replacement: AutomaticReversibleReplacement,
        in environment: InputSessionEnvironment
    ) -> AutomaticCorrectionResult {
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

    private func isSeparator(_ event: InputSessionEvent) -> Bool { separator(from: event) != nil }

    private func separator(from event: InputSessionEvent) -> Character? {
        guard case let .text(_, output) = event, output.count == 1, let character = output.first,
              character == " " || character.isPunctuation else { return nil }
        return character
    }
}

private struct PendingCorrection {
    let original: String
    let candidate: String
    let suffix: String
    let sourceLayoutID: String
    let candidateLayoutID: String
    let identity: AutomaticFocusIdentity
    let configurationRevision: UInt64
    let policyRevision: UInt64
    let englishLayoutID: String
    let russianLayoutID: String

    init(
        original: String,
        candidate: String,
        suffix: Character?,
        sourceLayoutID: String,
        candidateLayoutID: String,
        environment: InputSessionEnvironment
    ) {
        self.original = original
        self.candidate = candidate
        self.suffix = suffix.map(String.init) ?? ""
        self.sourceLayoutID = sourceLayoutID
        self.candidateLayoutID = candidateLayoutID
        identity = .init(environment)
        configurationRevision = environment.configuration.revision
        policyRevision = environment.policy.revision
        englishLayoutID = environment.layouts.pair?.english.id ?? ""
        russianLayoutID = environment.layouts.pair?.russian.id ?? ""
    }

    func matches(_ environment: InputSessionEnvironment) -> Bool {
            environment.configuration.isAutomationEnabled &&
            environment.configuration.revision == configurationRevision &&
            environment.policy.revision == policyRevision &&
            environment.focus.isSupported &&
            environment.policy.allowsAutomaticCorrection &&
            identity.matches(environment) &&
            environment.layouts.activeLayoutID == sourceLayoutID &&
            environment.layouts.availableLayoutIDs.isSuperset(of: [sourceLayoutID, candidateLayoutID]) &&
            environment.layouts.pair?.english.id == englishLayoutID &&
            environment.layouts.pair?.russian.id == russianLayoutID
    }
}

private struct AutomaticReversibleReplacement {
    let original: String
    let candidate: String
    let sourceLayoutID: String
    let candidateLayoutID: String
    let identity: AutomaticFocusIdentity
    let configurationRevision: UInt64
    let policyRevision: UInt64
    let englishLayoutID: String
    let russianLayoutID: String
    var isShowingCandidate = true
    var suffix: String

    init(_ pending: PendingCorrection) {
        original = pending.original
        candidate = pending.candidate
        sourceLayoutID = pending.sourceLayoutID
        candidateLayoutID = pending.candidateLayoutID
        identity = pending.identity
        configurationRevision = pending.configurationRevision
        policyRevision = pending.policyRevision
        englishLayoutID = pending.englishLayoutID
        russianLayoutID = pending.russianLayoutID
        suffix = pending.suffix
    }

    var displayed: String { isShowingCandidate ? candidate : original }
    var displayedLayoutID: String { isShowingCandidate ? candidateLayoutID : sourceLayoutID }

    func toggled() -> Self {
        var replacement = self
        replacement.isShowingCandidate.toggle()
        return replacement
    }

    func matches(_ environment: InputSessionEnvironment) -> Bool {
        environment.configuration.revision == configurationRevision &&
            environment.policy.revision == policyRevision &&
            environment.focus.isSupported &&
            environment.policy.allowsAutomaticCorrection &&
            identity.matches(environment) &&
            environment.layouts.activeLayoutID == displayedLayoutID &&
            environment.layouts.availableLayoutIDs.isSuperset(of: [sourceLayoutID, candidateLayoutID]) &&
            environment.layouts.pair?.english.id == englishLayoutID &&
            environment.layouts.pair?.russian.id == russianLayoutID
    }
}

private struct AutomaticFocusIdentity {
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
