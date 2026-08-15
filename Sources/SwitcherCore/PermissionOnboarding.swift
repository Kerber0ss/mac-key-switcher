/// A macOS privacy permission required before the application can observe or change input.
public enum Permission: CaseIterable, Sendable, Equatable {
    case listenEvents
    case accessibility

    public var title: String {
        switch self {
        case .listenEvents:
            "Мониторинг ввода"
        case .accessibility:
            "Универсальный доступ"
        }
    }

    public var explanation: String {
        switch self {
        case .listenEvents:
            "Нужно, чтобы видеть физические клавиши и клики, не вмешиваясь в ввод."
        case .accessibility:
            "Нужно, чтобы перед исправлением подтвердить короткий фрагмент рядом с курсором и отправить подтверждённую замену без буфера обмена."
        }
    }
}

/// A single, privacy-safe view of the permissions needed by the MVP.
public struct PermissionSnapshot: Sendable, Equatable {
    public let listenEventsGranted: Bool
    public let accessibilityGranted: Bool

    public init(listenEventsGranted: Bool, accessibilityGranted: Bool) {
        self.listenEventsGranted = listenEventsGranted
        self.accessibilityGranted = accessibilityGranted
    }

    public var missingPermissions: [Permission] {
        [
            listenEventsGranted ? nil : .listenEvents,
            accessibilityGranted ? nil : .accessibility,
        ].compactMap { $0 }
    }

    /// Monitoring and every form of correction stay disabled until all privacy gates are open.
    public var canMonitor: Bool {
        missingPermissions.isEmpty
    }

    public var menuTitle: String {
        guard let missingPermission = missingPermissions.first else {
            return "Разрешения выданы"
        }
        return "Требуется разрешение: \(missingPermission.title)"
    }

    public var missingPermissionsMessage: String {
        missingPermissions.map(\.title).joined(separator: ", ")
    }
}

/// A single, ordered first-run scenario: choose the layout pair, acknowledge the
/// privacy contract, then grant the two required permissions one at a time.
///
/// The flow is a pure, testable value: it derives the current step from the
/// inputs alone and holds no side effects. The host UI reads `step` to render
/// and `pendingPermission` to know which permission to request next.
public struct OnboardingFlow: Sendable, Equatable {
    /// A single stage of the first-run scenario, in order.
    public enum Step: Int, CaseIterable, Sendable, Equatable {
        case chooseLayouts
        case privacy
        case grantListenEvents
        case grantAccessibility
        case done
    }

    /// Whether the user has selected a valid, distinct layout pair.
    public let layoutPairSelected: Bool
    /// Whether the user has acknowledged the privacy explanation.
    public let privacyAcknowledged: Bool
    /// The current privacy-permission snapshot.
    public let permissions: PermissionSnapshot

    public init(
        layoutPairSelected: Bool,
        privacyAcknowledged: Bool,
        permissions: PermissionSnapshot
    ) {
        self.layoutPairSelected = layoutPairSelected
        self.privacyAcknowledged = privacyAcknowledged
        self.permissions = permissions
    }

    /// The step the user is currently on, derived from the inputs.
    public var step: Step {
        guard layoutPairSelected else { return .chooseLayouts }
        guard privacyAcknowledged else { return .privacy }
        guard permissions.listenEventsGranted else { return .grantListenEvents }
        guard permissions.accessibilityGranted else { return .grantAccessibility }
        return .done
    }

    /// The permission the current step asks the user to grant, if any.
    /// Permissions are always requested one at a time in a fixed order:
    /// monitoring first, then accessibility.
    public var pendingPermission: Permission? {
        switch step {
        case .grantListenEvents:
            return .listenEvents
        case .grantAccessibility:
            return .accessibility
        case .chooseLayouts, .privacy, .done:
            return nil
        }
    }

    /// True once every stage is satisfied and monitoring may begin.
    public var isComplete: Bool {
        step == .done
    }

    /// 1-based ordinal of the current step, for a calm "step N of M" progress hint.
    public var stepNumber: Int {
        step.rawValue + 1
    }

    /// Total number of stages the user walks through before "Готово".
    public var totalSteps: Int {
        Step.allCases.count - 1
    }
}
