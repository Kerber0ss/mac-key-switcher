import AppKit
import ApplicationServices
import Carbon
import SwitcherCore

@MainActor
final class SystemPermissionService {
    func snapshot() -> PermissionSnapshot {
        PermissionSnapshot(
            listenEventsGranted: CGPreflightListenEventAccess(),
            accessibilityGranted: AXIsProcessTrusted()
        )
    }

    func request(_ permission: Permission) {
        switch permission {
        case .listenEvents:
            CGRequestListenEventAccess()
        case .accessibility:
            AXIsProcessTrustedWithOptions([
                "AXTrustedCheckOptionPrompt": true,
            ] as CFDictionary)
        }
    }

    func openSystemSettings(for permission: Permission) {
        let pane: String
        switch permission {
        case .listenEvents:
            pane = "Privacy_ListenEvent"
        case .accessibility:
            pane = "Privacy_Accessibility"
        }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }
}

final class CGEventTapSource: PassiveInputEventSource, @unchecked Sendable {
    static let applicationEventMarker: Int64 = 0x4D4B53

    private var handler: (@Sendable (PassiveInputEvent) -> Void)?
    private var failureHandler: (@Sendable (PassiveEventMonitorFailure) -> Void)?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    func start(
        receiving handler: @escaping @Sendable (PassiveInputEvent) -> Void,
        onFailure: @escaping @Sendable (PassiveEventMonitorFailure) -> Void
    ) -> Bool {
        self.handler = handler
        failureHandler = onFailure

        let eventTypes: [CGEventType] = [
            .keyDown, .keyUp, .flagsChanged,
            .leftMouseDown, .leftMouseUp,
            .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp,
        ]
        let eventMask = eventTypes.reduce(CGEventMask()) { mask, type in
            mask | (CGEventMask(1) << type.rawValue)
        }
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            self.handler = nil
            failureHandler = nil
            return false
        }

        self.eventTap = eventTap
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        self.runLoopSource = runLoopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        return true
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        handler = nil
        failureHandler = nil
    }

    fileprivate func receive(_ event: PassiveInputEvent) {
        handler?(event)
    }

    fileprivate func report(_ failure: PassiveEventMonitorFailure) {
        DispatchQueue.main.async { [weak self] in
            self?.failureHandler?(failure)
        }
    }

    fileprivate func normalize(type: CGEventType, event: CGEvent) -> PassiveInputEvent? {
        let kind: PassiveInputEvent.Kind
        switch type {
        case .keyDown:
            kind = .keyDown
        case .keyUp:
            kind = .keyUp
        case .flagsChanged:
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            switch keyCode {
            case UInt16(kVK_Shift):
                // Resolve down/up from the left key's own device-dependent bit,
                // never the aggregate .maskShift (true while either Shift is held).
                kind = ShiftFlagsDecoder.direction(for: .left, flagsRawValue: event.flags.rawValue)
            case UInt16(kVK_RightShift):
                kind = ShiftFlagsDecoder.direction(for: .right, flagsRawValue: event.flags.rawValue)
            case UInt16(kVK_CapsLock):
                // Caps Lock is a toggle: both turning it on and turning it off are a command press.
                kind = .keyDown
            default:
                return nil
            }
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            kind = .mouseDown
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            kind = .mouseUp
        default:
            return nil
        }
        let keyCode = (type == .keyDown || type == .keyUp || type == .flagsChanged)
            ? UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            : nil
        return PassiveInputEvent(
            kind: kind,
            keyCode: keyCode,
            modifierFlags: event.flags.rawValue,
            timestampMilliseconds: event.timestamp / 1_000_000,
            isMarkedByApplication: event.getIntegerValueField(.eventSourceUserData) == Self.applicationEventMarker
        )
    }
}

private func eventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let source = Unmanaged<CGEventTapSource>.fromOpaque(userInfo).takeUnretainedValue()
    switch type {
    case .tapDisabledByTimeout:
        source.report(.queueOverflow)
    case .tapDisabledByUserInput:
        source.report(.secureEventInput)
    default:
        break
    }
    if let normalizedEvent = source.normalize(type: type, event: event) {
        source.receive(normalizedEvent)
    }
    return Unmanaged.passUnretained(event)
}
