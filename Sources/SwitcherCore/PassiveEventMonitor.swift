import Foundation

/// A normalized physical event. It deliberately contains no typed characters or text.
public struct PassiveInputEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case keyDown
        case keyUp
        case mouseDown
        case mouseUp
    }

    public let kind: Kind
    public let keyCode: UInt16?
    /// Modifier flags from the physical event. They contain no text.
    public let modifierFlags: UInt64
    /// Monotonic event time, used only to recognize Double Shift.
    public let timestampMilliseconds: UInt64
    public let isMarkedByApplication: Bool

    public init(
        kind: Kind,
        keyCode: UInt16?,
        modifierFlags: UInt64 = 0,
        timestampMilliseconds: UInt64 = 0,
        isMarkedByApplication: Bool
    ) {
        self.kind = kind
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags
        self.timestampMilliseconds = timestampMilliseconds
        self.isMarkedByApplication = isMarkedByApplication
    }
}

/// An event plus the monitor generation that accepted it.
///
/// Consumers that hop to another executor must call `PassiveInputEventDeliveryGate.accepts(_:)`
/// immediately before using the event.
public struct PassiveInputEventDelivery: Sendable {
    public let event: PassiveInputEvent
    fileprivate let generation: UInt64

    fileprivate init(event: PassiveInputEvent, generation: UInt64) {
        self.event = event
        self.generation = generation
    }
}

/// Shares the validity of event deliveries with a consumer on another executor.
public final class PassiveInputEventDeliveryGate: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0

    public init() {}

    public func accepts(_ delivery: PassiveInputEventDelivery) -> Bool {
        lock.withLock { generation == delivery.generation }
    }

    fileprivate func makeDelivery(for event: PassiveInputEvent) -> PassiveInputEventDelivery {
        lock.withLock { .init(event: event, generation: generation) }
    }

    fileprivate func invalidate() {
        lock.withLock { generation &+= 1 }
    }
}

/// The system boundary that supplies normalized listen-only input events.
public protocol PassiveInputEventSource: AnyObject {
    func start(
        receiving handler: @escaping @Sendable (PassiveInputEvent) -> Void,
        onFailure: @escaping @Sendable (PassiveEventMonitorFailure) -> Void
    ) -> Bool
    func stop()
}

/// A condition that makes the stream of physical events unreliable.
public enum PassiveEventMonitorFailure: Sendable, Equatable {
    case tapDisabled
    case eventLost
    case queueOverflow
    case secureEventInput
}

public enum PassiveEventMonitorState: Sendable, Equatable {
    case stopped
    case running
    case recovering
    case failed
}

/// Delivers unmarked physical events in order and never suppresses or replays them.
public final class PassiveEventMonitor: @unchecked Sendable {
    private let source: PassiveInputEventSource
    private let onEvent: @Sendable (PassiveInputEventDelivery) -> Void
    private let onFailure: @Sendable (PassiveEventMonitorFailure) -> Void
    private let deliveryGate: PassiveInputEventDeliveryGate
    private let lock = NSLock()
    private let processingQueue = DispatchQueue(label: "MacKeySwitcher.PassiveEventMonitor")
    private var currentState = PassiveEventMonitorState.stopped
    private var recoveryAttempts = 0
    private static let maximumRecoveryAttempts = 1

    public init(
        source: PassiveInputEventSource,
        onEvent: @escaping @Sendable (PassiveInputEventDelivery) -> Void,
        onFailure: @escaping @Sendable (PassiveEventMonitorFailure) -> Void = { _ in },
        deliveryGate: PassiveInputEventDeliveryGate = .init()
    ) {
        self.source = source
        self.onEvent = onEvent
        self.onFailure = onFailure
        self.deliveryGate = deliveryGate
    }

    public var state: PassiveEventMonitorState {
        lock.withLock { currentState }
    }

    public func start() {
        guard setStateIfStopped(.running) else { return }
        recoveryAttempts = 0
        guard startSource() else { setState(.failed); return }
    }

    public func stop() {
        source.stop()
        invalidateEventsAndSetState(.stopped)
    }

    /// The platform boundary calls this before attempting to recover its event tap.
    public func reportFailure(_ failure: PassiveEventMonitorFailure) {
        guard beginRecovery() else { return }
        onFailure(failure)
        source.stop()
        guard recoveryAttempts < Self.maximumRecoveryAttempts else {
            setState(.failed)
            return
        }
        recoveryAttempts += 1
        setState(.recovering)
        guard startSource() else { setState(.failed); return }
        setState(.running)
    }

    private func receive(_ event: PassiveInputEvent) {
        let delivery = deliveryGate.makeDelivery(for: event)
        processingQueue.async { [weak self] in
            guard
                let self,
                self.isRunning,
                self.deliveryGate.accepts(delivery),
                !event.isMarkedByApplication
            else { return }
            self.onEvent(delivery)
        }
    }

    private func startSource() -> Bool {
        source.start(receiving: { [weak self] event in
            self?.receive(event)
        }, onFailure: { [weak self] failure in
            self?.reportFailure(failure)
        })
    }

    private func setState(_ state: PassiveEventMonitorState) {
        lock.withLock { currentState = state }
    }

    private func invalidateEventsAndSetState(_ state: PassiveEventMonitorState) {
        deliveryGate.invalidate()
        lock.withLock {
            currentState = state
        }
    }

    private func beginRecovery() -> Bool {
        let canRecover = lock.withLock {
            guard currentState == .running || currentState == .recovering else { return false }
            currentState = .recovering
            return true
        }
        if canRecover { deliveryGate.invalidate() }
        return canRecover
    }

    private var isRunning: Bool {
        lock.withLock { currentState == .running }
    }

    private func setStateIfStopped(_ state: PassiveEventMonitorState) -> Bool {
        lock.withLock {
            guard currentState == .stopped else { return false }
            currentState = state
            return true
        }
    }
}
