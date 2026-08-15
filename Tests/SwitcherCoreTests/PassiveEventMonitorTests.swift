import Foundation
import XCTest
@testable import SwitcherCore

final class PassiveEventMonitorTests: XCTestCase {
    func testMonitorForwardsOnlyUnmarkedPhysicalEvents() {
        let source = TestEventSource()
        let received = EventReceipt(expectedCount: 2)
        let monitor = PassiveEventMonitor(source: source, onEvent: { received.record($0.event) })

        monitor.start()
        source.emit(.init(kind: .keyDown, keyCode: 12, isMarkedByApplication: false))
        source.emit(.init(kind: .mouseDown, keyCode: nil, isMarkedByApplication: true))
        source.emit(.init(kind: .mouseUp, keyCode: nil, isMarkedByApplication: false))

        wait(for: [received.fulfilled], timeout: 1)
        XCTAssertEqual(monitor.state, .running)
        XCTAssertEqual(received.events, [
            .init(kind: .keyDown, keyCode: 12, isMarkedByApplication: false),
            .init(kind: .mouseUp, keyCode: nil, isMarkedByApplication: false),
        ])
    }

    func testMonitorReportsFailureWhenTheEventSourceCannotStart() {
        let monitor = PassiveEventMonitor(source: TestEventSource(canStart: false), onEvent: { _ in })

        monitor.start()

        XCTAssertEqual(monitor.state, .failed)
    }

    func testFailureClearsTheConsumerBeforeOneBoundedRecoveryThenFails() {
        let source = TestEventSource()
        let receipt = FailureReceipt()
        let monitor = PassiveEventMonitor(source: source, onEvent: { _ in }, onFailure: receipt.record)

        monitor.start()
        source.fail(.secureEventInput)
        XCTAssertEqual(monitor.state, .running)
        source.fail(.queueOverflow)

        XCTAssertEqual(receipt.failures, [.secureEventInput, .queueOverflow])
        XCTAssertEqual(source.startCount, 2)
        XCTAssertEqual(monitor.state, .failed)
    }

    func testEveryUnreliableInputConditionNotifiesTheFailClosedBoundaryBeforeRetrying() {
        for failure in [
            PassiveEventMonitorFailure.tapDisabled,
            .eventLost,
            .queueOverflow,
            .secureEventInput,
        ] {
            let source = TestEventSource()
            let receipt = FailureReceipt()
            let monitor = PassiveEventMonitor(source: source, onEvent: { _ in }, onFailure: receipt.record)

            monitor.start()
            source.fail(failure)

            XCTAssertEqual(receipt.failures, [failure])
            XCTAssertEqual(source.startCount, 2)
            XCTAssertEqual(monitor.state, .running)
        }
    }

    func testFailureDropsEventsQueuedBeforeRecovery() {
        let source = TestEventSource()
        let firstEventEntered = DispatchSemaphore(value: 0)
        let allowFirstEventToFinish = DispatchSemaphore(value: 0)
        let receipt = EventReceipt(expectedCount: 1)
        let monitor = PassiveEventMonitor(source: source, onEvent: { delivery in
            if delivery.event.keyCode == 1 {
                firstEventEntered.signal()
                allowFirstEventToFinish.wait()
            }
            receipt.record(delivery.event)
        })

        monitor.start()
        source.emit(.init(kind: .keyDown, keyCode: 1, isMarkedByApplication: false))
        XCTAssertEqual(firstEventEntered.wait(timeout: .now() + 1), .success)
        source.emit(.init(kind: .keyDown, keyCode: 2, isMarkedByApplication: false))
        source.fail(.eventLost)
        allowFirstEventToFinish.signal()

        wait(for: [receipt.fulfilled], timeout: 1)
        XCTAssertEqual(receipt.events.map(\.keyCode), [1])
    }

    func testDeliveryFromBeforeFailureIsRejectedAfterAnExecutorHop() {
        let source = TestEventSource()
        let receipt = DeliveryReceipt()
        let gate = PassiveInputEventDeliveryGate()
        let monitor = PassiveEventMonitor(source: source, onEvent: receipt.record, deliveryGate: gate)

        monitor.start()
        source.emit(.init(kind: .keyDown, keyCode: 1, isMarkedByApplication: false))
        wait(for: [receipt.fulfilled], timeout: 1)
        source.fail(.eventLost)

        XCTAssertFalse(gate.accepts(receipt.delivery!))
    }
}

private final class FailureReceipt: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedFailures: [PassiveEventMonitorFailure] = []

    var failures: [PassiveEventMonitorFailure] { lock.withLock { recordedFailures } }

    func record(_ failure: PassiveEventMonitorFailure) {
        lock.withLock { recordedFailures.append(failure) }
    }
}

private final class TestEventSource: PassiveInputEventSource, @unchecked Sendable {
    private var handler: (@Sendable (PassiveInputEvent) -> Void)?
    private var failureHandler: (@Sendable (PassiveEventMonitorFailure) -> Void)?
    private let canStart: Bool
    private(set) var startCount = 0

    init(canStart: Bool = true) {
        self.canStart = canStart
    }

    func start(receiving handler: @escaping @Sendable (PassiveInputEvent) -> Void, onFailure: @escaping @Sendable (PassiveEventMonitorFailure) -> Void) -> Bool {
        startCount += 1
        guard canStart else { return false }
        self.handler = handler
        failureHandler = onFailure
        return true
    }

    func stop() {
        handler = nil
        failureHandler = nil
    }

    func emit(_ event: PassiveInputEvent) {
        handler?(event)
    }

    func fail(_ failure: PassiveEventMonitorFailure) {
        failureHandler?(failure)
    }
}

private final class EventReceipt: @unchecked Sendable {
    let fulfilled: XCTestExpectation
    private let lock = NSLock()
    private var recordedEvents: [PassiveInputEvent] = []

    init(expectedCount: Int) {
        fulfilled = XCTestExpectation(description: "physical events received")
        fulfilled.expectedFulfillmentCount = expectedCount
    }

    var events: [PassiveInputEvent] {
        lock.withLock { recordedEvents }
    }

    func record(_ event: PassiveInputEvent) {
        lock.withLock { recordedEvents.append(event) }
        fulfilled.fulfill()
    }
}

private final class DeliveryReceipt: @unchecked Sendable {
    let fulfilled = XCTestExpectation(description: "physical event delivery received")
    private let lock = NSLock()
    private var recordedDelivery: PassiveInputEventDelivery?

    var delivery: PassiveInputEventDelivery? { lock.withLock { recordedDelivery } }

    func record(_ delivery: PassiveInputEventDelivery) {
        lock.withLock { recordedDelivery = delivery }
        fulfilled.fulfill()
    }
}
