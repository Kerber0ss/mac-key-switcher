import Foundation

/// Persistent user choices that control automatic correction without affecting Double Shift.
public struct AutomationSettings: Sendable, Equatable {
    public let revision: UInt64
    public let isAutomationEnabled: Bool
    public let wordExceptions: Set<String>
    public let manualConversionShortcut: ManualConversionShortcut

    public init(
        revision: UInt64,
        isAutomationEnabled: Bool,
        wordExceptions: Set<String>,
        manualConversionShortcut: ManualConversionShortcut = .doubleShift
    ) {
        self.revision = revision
        self.isAutomationEnabled = isAutomationEnabled
        self.wordExceptions = Set(wordExceptions.compactMap(normalizedWordException))
        self.manualConversionShortcut = manualConversionShortcut
    }

    public func excludes(_ word: String) -> Bool {
        normalizedWordException(word).map(wordExceptions.contains) ?? false
    }
}

/// A user-selected physical command for converting the current or previous word.
public enum ManualConversionShortcut: Sendable, Equatable {
    case doubleShift
    case key(keyCode: UInt16, modifierFlags: UInt64)
}

public enum AutomationSettingsCommand: Sendable, Equatable {
    case setAutomationEnabled(Bool)
    case addWordException(String)
    case removeWordException(String)
    case setManualConversionShortcut(ManualConversionShortcut)
}

/// UserDefaults-backed settings store. Each effective change advances the session revision.
public final class AutomationSettingsStore: @unchecked Sendable {
    private enum Key {
        static let automationEnabled = "automationEnabled"
        static let wordExceptions = "wordExceptions"
        static let manualConversionShortcutKind = "manualConversionShortcutKind"
        static let manualConversionShortcutKeyCode = "manualConversionShortcutKeyCode"
        static let manualConversionShortcutModifierFlags = "manualConversionShortcutModifierFlags"
        static let revision = "automationSettingsRevision"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var snapshot: AutomationSettings {
        AutomationSettings(
            revision: UInt64(defaults.integer(forKey: Key.revision)),
            isAutomationEnabled: defaults.object(forKey: Key.automationEnabled) as? Bool ?? true,
            wordExceptions: Set(
                (defaults.stringArray(forKey: Key.wordExceptions) ?? []).compactMap(normalizedWordException)
            ),
            manualConversionShortcut: shortcut
        )
    }

    @discardableResult
    public func apply(_ command: AutomationSettingsCommand) -> AutomationSettings {
        let current = snapshot
        switch command {
        case let .setAutomationEnabled(isEnabled):
            guard current.isAutomationEnabled != isEnabled else { return current }
            defaults.set(isEnabled, forKey: Key.automationEnabled)
        case let .addWordException(word):
            guard let normalized = normalizedWordException(word) else {
                return current
            }
            var exceptions = current.wordExceptions
            guard exceptions.insert(normalized).inserted else { return current }
            defaults.set(exceptions.sorted(), forKey: Key.wordExceptions)
        case let .removeWordException(word):
            guard let normalized = normalizedWordException(word) else {
                return current
            }
            var exceptions = current.wordExceptions
            guard exceptions.remove(normalized) != nil else { return current }
            defaults.set(exceptions.sorted(), forKey: Key.wordExceptions)
        case let .setManualConversionShortcut(shortcut):
            guard current.manualConversionShortcut != shortcut else { return current }
            switch shortcut {
            case .doubleShift:
                defaults.set("doubleShift", forKey: Key.manualConversionShortcutKind)
                defaults.removeObject(forKey: Key.manualConversionShortcutKeyCode)
                defaults.removeObject(forKey: Key.manualConversionShortcutModifierFlags)
            case let .key(keyCode, modifierFlags):
                defaults.set("key", forKey: Key.manualConversionShortcutKind)
                defaults.set(Int(keyCode), forKey: Key.manualConversionShortcutKeyCode)
                defaults.set(String(modifierFlags), forKey: Key.manualConversionShortcutModifierFlags)
            }
        }
        defaults.set(defaults.integer(forKey: Key.revision) + 1, forKey: Key.revision)
        return snapshot
    }

    private var shortcut: ManualConversionShortcut {
        guard
            defaults.string(forKey: Key.manualConversionShortcutKind) == "key",
            let keyCode = UInt16(exactly: defaults.integer(forKey: Key.manualConversionShortcutKeyCode))
        else { return .doubleShift }
        return .key(
            keyCode: keyCode,
            modifierFlags: defaults.string(forKey: Key.manualConversionShortcutModifierFlags).flatMap(UInt64.init) ?? 0
        )
    }
}

public func normalizedWordException(_ word: String) -> String? {
    let normalized = word
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .precomposedStringWithCanonicalMapping
        .lowercased()
        .precomposedStringWithCanonicalMapping
    return normalized.isEmpty ? nil : normalized
}
