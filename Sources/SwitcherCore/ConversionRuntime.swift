import Foundation

/// Single dispatch layer that recognizes the manual command once and routes it
/// to the coordinators.
///
/// Previously both coordinators ran their own identical Double Shift state
/// machine, and the system runtime had to defensively call
/// `manual.closeSession()` whenever automatic correction consumed the command,
/// to stop manual conversion from re-applying a stale copy of the same word.
/// That desynchronization is removed here: a single `ManualCommandRecognizer`
/// decides when the command fires, and this runtime hands each coordinator a
/// ready "command performed" signal with a fixed priority (automatic first),
/// so exactly one coordinator can apply it.
public final class ConversionRuntime: @unchecked Sendable {
    /// What the caller (the platform boundary) must do after one event.
    public enum Outcome: Sendable, Equatable {
        /// Nothing to do.
        case ignored
        /// A coordinator failed closed; the caller must close the whole session.
        case failed
        /// Automatic correction is armed and its pending correction should run
        /// once the event queue has yielded (`performPendingCorrection`).
        case scheduledPendingCorrection
        /// The recognized command toggled or applied a conversion.
        case commandApplied
    }

    private let automatic: AutomaticCorrectionCoordinator
    private let manual: ManualConversionCoordinator
    private var recognizer = ManualCommandRecognizer()

    public init(
        automatic: AutomaticCorrectionCoordinator,
        manual: ManualConversionCoordinator
    ) {
        self.automatic = automatic
        self.manual = manual
    }

    /// Feeds one normalized event to both coordinators and, when it completes a
    /// command, applies it exactly once.
    @discardableResult
    public func receive(
        _ event: InputSessionEvent,
        in environment: InputSessionEnvironment
    ) -> Outcome {
        let commandRecognized = recognizer.consume(event)

        let automaticResult = automatic.receive(event, in: environment)
        if automaticResult.isFailure { return .failed }

        let manualResult = manual.receive(event, in: environment)
        if manualResult.isFailure { return .failed }

        if commandRecognized {
            return applyCommand(in: environment)
        }

        if automaticResult == .pending {
            return .scheduledPendingCorrection
        }
        return .ignored
    }

    /// Runs the deferred automatic correction; returns `false` if it failed
    /// closed so the caller can close the session.
    @discardableResult
    public func performPendingCorrection(in environment: InputSessionEnvironment) -> Bool {
        !automatic.performPendingCorrection(in: environment).isFailure
    }

    public func closeSession() {
        recognizer.reset()
        automatic.closeSession()
        manual.closeSession()
    }

    public var automaticCorrectionIsAvailable: Bool {
        automatic.availability == .available && manual.availability == .available
    }

    /// Applies a recognized command with automatic priority.  When automatic
    /// correction reverses its own replacement, manual conversion is dropped so
    /// it can never re-apply a stale copy over the restored text.
    private func applyCommand(in environment: InputSessionEnvironment) -> Outcome {
        let automaticCommand = automatic.performCommand(in: environment)
        if automaticCommand.isFailure { return .failed }
        if automaticCommand == .replaced {
            manual.closeSession()
            return .commandApplied
        }
        let manualCommand = manual.performCommand(in: environment)
        if manualCommand.isFailure { return .failed }
        return manualCommand == .replaced ? .commandApplied : .ignored
    }
}

private extension AutomaticCorrectionResult {
    var isFailure: Bool {
        switch self {
        case .rejected, .injectionFailed, .postVerificationFailed, .layoutSelectionFailed: true
        case .ignored, .pending, .cancelled, .replaced: false
        }
    }
}

private extension ManualConversionResult {
    var isFailure: Bool {
        switch self {
        case .rejected, .injectionFailed, .postVerificationFailed, .layoutSelectionFailed: true
        case .ignored, .replaced: false
        }
    }
}
