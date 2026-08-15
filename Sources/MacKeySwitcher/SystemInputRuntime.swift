import AppKit
import ApplicationServices
import Carbon
import SwitcherCore

@MainActor
final class LayoutPairStore {
    private enum Key {
        static let englishID = "englishKeyboardLayoutID"
        static let russianID = "russianKeyboardLayoutID"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func pair(in layouts: [KeyboardLayout]) -> LayoutPair? {
        guard case let .success(pair) = LayoutPair.select(
            englishID: defaults.string(forKey: Key.englishID),
            russianID: defaults.string(forKey: Key.russianID),
            from: layouts
        ) else { return nil }
        return pair
    }

    func selectedIDs() -> (english: String, russian: String) {
        (defaults.string(forKey: Key.englishID) ?? "", defaults.string(forKey: Key.russianID) ?? "")
    }

    @discardableResult
    func save(englishID: String, russianID: String, in layouts: [KeyboardLayout]) -> Bool {
        guard case .success = LayoutPair.select(
            englishID: englishID,
            russianID: russianID,
            from: layouts
        ) else { return false }
        defaults.set(englishID, forKey: Key.englishID)
        defaults.set(russianID, forKey: Key.russianID)
        return true
    }
}

final class SystemFocusInspector: FocusInspector, @unchecked Sendable {
    private let identityLock = NSLock()
    private var lastElement: AXUIElement?
    private var lastElementID: UInt64 = 0

    func snapshot() -> (InputFocusSnapshot, ApplicationInputContext) {
        guard let context = focusedContext() else {
            let application = NSWorkspace.shared.frontmostApplication
            return (
                .init(
                    applicationID: application?.bundleIdentifier ?? "",
                    elementID: "unavailable",
                    processID: application?.processIdentifier ?? 0,
                    isSupported: application != nil
                ),
                .unknown
            )
        }
        let protected = context.isProtected
        let applicationID = NSRunningApplication(processIdentifier: context.processID)?.bundleIdentifier
            ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            ?? ""
        return (
            .init(
                applicationID: applicationID,
                elementID: elementID(for: context.element),
                processID: context.processID,
                isSupported: !protected
            ),
            protected ? .protected : .supported
        )
    }

    func replacementProof(beforeCursorCount: Int) -> ReplacementProof {
        guard let context = focusedContext(),
              context.isEditable,
              !context.isProtected
        else { return .unavailable }
        let role: FocusInspection.Role
        switch context.role {
        case kAXTextFieldRole:
            role = .textField
        case kAXTextAreaRole, "AXWebArea":
            role = .textArea
        default:
            return .opaque
        }
        guard let selection = selectedRange(of: context.element),
              selection.length == 0,
              selection.location >= beforeCursorCount,
              let localText = text(
                in: context.element,
                range: .init(location: selection.location - beforeCursorCount, length: beforeCursorCount)
              )
        else { return .opaque }
        return .exact(.init(
            processID: context.processID,
            elementID: elementID(for: context.element),
            role: role,
            isEditable: context.isEditable,
            isProtected: context.isProtected,
            selection: .init(location: selection.location, length: selection.length),
            localTextBeforeCursor: localText
        ))
    }

    private func focusedContext() -> (element: AXUIElement, processID: pid_t, role: String, isEditable: Bool, isProtected: Bool)? {
        let systemWide = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let element = AXValueCasting.uiElement(from: value) else { return nil }
        var processID: pid_t = 0
        guard AXUIElementGetPid(element, &processID) == .success,
              let role = stringAttribute(kAXRoleAttribute, of: element)
        else { return nil }
        let subrole = stringAttribute(kAXSubroleAttribute, of: element)
        var selectedTextRangeIsSettable: DarwinBoolean = false
        let settableStatus = AXUIElementIsAttributeSettable(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &selectedTextRangeIsSettable
        )
        let isEditable = boolAttribute("AXEditable", of: element)
            ?? (settableStatus == .success && selectedTextRangeIsSettable.boolValue)
        let isProtected = role == "AXSecureTextField" ||
            subrole?.localizedCaseInsensitiveContains("secure") == true ||
            subrole?.localizedCaseInsensitiveContains("password") == true
        return (element, processID, role, isEditable, isProtected)
    }

    private func selectedRange(of element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let rangeValue = AXValueCasting.axValue(from: value) else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &range) else { return nil }
        return range
    }

    private func text(in element: AXUIElement, range: CFRange) -> String? {
        var requestedRange = range
        guard let rangeValue = AXValueCreate(.cfRange, &requestedRange) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            rangeValue,
            &value
        ) == .success else { return nil }
        return value as? String
    }

    private func stringAttribute(_ attribute: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func boolAttribute(_ attribute: String, of element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? Bool
    }

    private func elementID(for element: AXUIElement) -> String {
        identityLock.withLock {
            if let lastElement, CFEqual(lastElement, element) {
                return String(lastElementID)
            }
            lastElement = element
            lastElementID &+= 1
            return String(lastElementID)
        }
    }

}

final class SystemTextInjector: TextInjector, @unchecked Sendable {
    func sendMarkedBackspaces(_ count: Int) -> Bool {
        guard count >= 0 else { return false }
        return (0 ..< count).allSatisfy { _ in postKey(virtualKey: CGKeyCode(kVK_Delete)) }
    }

    func sendMarkedUnicode(_ text: String) -> Bool {
        guard !text.isEmpty else { return true }
        guard
            let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
            let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
        else { return false }
        let unicode = Array(text.utf16)
        mark(down)
        mark(up)
        down.keyboardSetUnicodeString(stringLength: unicode.count, unicodeString: unicode)
        up.keyboardSetUnicodeString(stringLength: unicode.count, unicodeString: unicode)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    private func postKey(virtualKey: CGKeyCode) -> Bool {
        guard
            let down = CGEvent(keyboardEventSource: nil, virtualKey: virtualKey, keyDown: true),
            let up = CGEvent(keyboardEventSource: nil, virtualKey: virtualKey, keyDown: false)
        else { return false }
        mark(down)
        mark(up)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    private func mark(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: CGEventTapSource.applicationEventMarker)
    }
}

@MainActor
final class SystemInputRuntime {
    private let catalog: InputSourceCatalog
    private let layoutPairStore: LayoutPairStore
    private let focusInspector = SystemFocusInspector()
    private let textInjector = SystemTextInjector()
    private let automationSettings: AutomationSettingsStore
    private let excludedApplications: ExcludedApplicationStore
    private lazy var translate: InputSessionReducer.Translate = { [catalog] layout, stroke in
        catalog.output(for: stroke, in: layout.id)
    }
    private lazy var manual = ManualConversionCoordinator(
        focusInspector: focusInspector,
        textInjector: textInjector,
        inputSourceService: inputSourceService,
        translate: translate
    )
    private lazy var automatic = AutomaticCorrectionCoordinator(
        focusInspector: focusInspector,
        textInjector: textInjector,
        inputSourceService: inputSourceService,
        detector: .init(resources: .minimum),
        translate: translate
    )
    private lazy var conversion = ConversionRuntime(automatic: automatic, manual: manual)
    private lazy var inputSourceService = CatalogInputSourceService(catalog: catalog)

    init(
        catalog: InputSourceCatalog,
        layoutPairStore: LayoutPairStore,
        automationSettings: AutomationSettingsStore,
        excludedApplications: ExcludedApplicationStore
    ) {
        self.catalog = catalog
        self.layoutPairStore = layoutPairStore
        self.automationSettings = automationSettings
        self.excludedApplications = excludedApplications
    }

    func receive(_ passiveEvent: PassiveInputEvent) {
        guard let event = normalizedEvent(from: passiveEvent) else {
            return
        }
        guard let environment = environment() else {
            closeSession()
            return
        }
        switch conversion.receive(event, in: environment) {
        case .failed:
            closeSession()
        case .scheduledPendingCorrection:
            DispatchQueue.main.async { [weak self] in
                guard let self, let currentEnvironment = self.environment() else { return }
                if !self.conversion.performPendingCorrection(in: currentEnvironment) {
                    self.closeSession()
                }
            }
        case .ignored, .commandApplied:
            break
        }
    }

    func closeSession() {
        conversion.closeSession()
    }

    var automaticCorrectionIsAvailable: Bool {
        conversion.automaticCorrectionIsAvailable
    }

    private func environment() -> InputSessionEnvironment? {
        guard let activeLayoutID = catalog.currentLayoutID() else { return nil }
        let (focus, context) = focusInspector.snapshot()
        let layouts = catalog.layouts
        return .init(
            configuration: .init(settings: automationSettings.snapshot),
            focus: focus,
            policy: excludedApplications.policy().permissions(for: focus.applicationID.isEmpty ? nil : focus.applicationID, context: context),
            layouts: .init(
                pair: layoutPairStore.pair(in: layouts),
                availableLayoutIDs: Set(layouts.map(\.id)),
                activeLayoutID: activeLayoutID
            )
        )
    }

    private func normalizedEvent(from event: PassiveInputEvent) -> InputSessionEvent? {
        if event.kind == .keyDown,
           automationSettings.snapshot.manualConversionShortcut.matches(
            keyCode: event.keyCode,
            modifierFlags: relevantModifierFlags(event.modifierFlags)
           ) {
            return .manualCommand
        }
        switch event.kind {
        case .mouseDown:
            return .mouseClick
        case .mouseUp:
            return nil
        case .keyUp:
            switch event.keyCode {
            case UInt16(kVK_Shift): return .shiftUp(.left, milliseconds: event.timestampMilliseconds)
            case UInt16(kVK_RightShift): return .shiftUp(.right, milliseconds: event.timestampMilliseconds)
            default: return nil
            }
        case .keyDown:
            guard let keyCode = event.keyCode else { return .inputLost }
            switch keyCode {
            case UInt16(kVK_Shift): return .shiftDown(.left, milliseconds: event.timestampMilliseconds)
            case UInt16(kVK_RightShift): return .shiftDown(.right, milliseconds: event.timestampMilliseconds)
            case UInt16(kVK_Return): return .returnKey
            case UInt16(kVK_ANSI_KeypadEnter): return .enterKey
            case UInt16(kVK_Tab): return .tab
            case UInt16(kVK_Escape): return .escape
            case UInt16(kVK_Delete): return .backspace
            case UInt16(kVK_ForwardDelete): return .forwardDelete
            case UInt16(kVK_LeftArrow), UInt16(kVK_RightArrow), UInt16(kVK_DownArrow), UInt16(kVK_UpArrow),
                 UInt16(kVK_Home), UInt16(kVK_End), UInt16(kVK_PageUp), UInt16(kVK_PageDown): return .navigation
            default: break
            }
            let flags = CGEventFlags(rawValue: event.modifierFlags)
            if flags.contains(.maskCommand) { return .commandCombination }
            if flags.contains(.maskAlternate) { return .optionCombination }
            let modifiers: KeyStroke.Modifiers = [
                flags.contains(.maskShift) ? .shift : [],
                flags.contains(.maskAlphaShift) ? .capsLock : [],
            ].reduce([]) { $0.union($1) }
            let stroke = KeyStroke(keyCode: keyCode, modifiers: modifiers)
            guard let layoutID = catalog.currentLayoutID(), let output = catalog.output(for: stroke, in: layoutID) else {
                return .deadKey
            }
            return .text(stroke, output: output)
        }
    }

    private func relevantModifierFlags(_ flags: UInt64) -> UInt64 {
        CGEventFlags(rawValue: flags)
            .intersection([.maskShift, .maskControl, .maskAlternate, .maskCommand])
            .rawValue
    }
}

private extension ManualConversionShortcut {
    func matches(keyCode: UInt16?, modifierFlags: UInt64) -> Bool {
        guard case let .key(expectedKeyCode, expectedModifierFlags) = self else { return false }
        return keyCode == expectedKeyCode && modifierFlags == expectedModifierFlags
    }
}

private final class CatalogInputSourceService: InputSourceService, @unchecked Sendable {
    private let catalog: InputSourceCatalog

    init(catalog: InputSourceCatalog) {
        self.catalog = catalog
    }

    func selectInputSource(id: String) -> Bool {
        catalog.select(layoutID: id)
    }
}
