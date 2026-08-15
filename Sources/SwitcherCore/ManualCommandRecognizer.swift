import Foundation

/// Recognizes the manual command exactly once for the whole runtime.
///
/// Previously both coordinators ran their own identical Double Shift state
/// machine, so a single physical Double Shift completed in *both* of them and
/// the runtime had to defensively suppress one of them.  Centralizing the
/// recognition here lets the dispatch layer hand each coordinator a ready
/// "command performed" signal instead, removing that race.
///
/// The command is either:
/// - **Double Shift** — two full single presses of the *same* physical Shift
///   key within `doubleShiftWindowMilliseconds`, with no intervening keys; or
/// - a **custom shortcut**, which the platform boundary has already collapsed
///   into a single `.manualCommand` event.
public struct ManualCommandRecognizer: Sendable {
    /// Two full presses of the same Shift key must fall inside this window.
    public static let doubleShiftWindowMilliseconds: UInt64 = 350

    private enum State: Sendable {
        case idle
        case pressed(ShiftSide)
        case released(ShiftSide, UInt64)
        case secondPressed(ShiftSide)
    }

    private var state: State = .idle

    public init() {}

    /// Feeds one normalized event and reports whether it completes a command.
    ///
    /// A `.manualCommand` fires immediately (already recognized at the boundary).
    /// Double Shift fires on the second release of the same key inside the
    /// window.  Any other event — a typed key, a different Shift, an input
    /// break — resets the partially observed sequence, so holding, combining,
    /// or interleaving keys can never be mistaken for the command.
    public mutating func consume(_ event: InputSessionEvent) -> Bool {
        if case .manualCommand = event {
            state = .idle
            return true
        }
        switch (state, event) {
        case let (.idle, .shiftDown(side, _)):
            state = .pressed(side)
        case let (.pressed(side), .shiftUp(releasedSide, time)) where side == releasedSide:
            state = .released(side, time)
        case let (.released(side, firstRelease), .shiftDown(nextSide, time))
            where side == nextSide && time >= firstRelease
            && time - firstRelease <= Self.doubleShiftWindowMilliseconds:
            state = .secondPressed(side)
        case let (.secondPressed(side), .shiftUp(releasedSide, _)) where side == releasedSide:
            state = .idle
            return true
        default:
            state = .idle
        }
        return false
    }

    /// Drops any partially observed sequence after an unreliable event stream.
    public mutating func reset() {
        state = .idle
    }
}
