/// Наблюдаемое базовое состояние до настройки пары раскладок и разрешений.
public enum ApplicationState: Sendable, Equatable {
    case missingPermissions
    case layoutPairUnavailable
    case languageResourcesFailed
    case eventMonitorFailed
    case automaticCorrectionFailed
    case ready
    case automationOff

    public static let initial = Self.missingPermissions

    public enum MenuAction: Sendable, Equatable {
        case openPermissions
        case openSettings
        case restartApplication
        case restartMonitor
        case toggleAutomation
    }

    /// Chooses the single recovery state shown by the menu.
    public static func resolve(
        permissionsGranted: Bool,
        layoutPairAvailable: Bool,
        languageResourcesAvailable: Bool,
        eventMonitorIsOperational: Bool,
        automaticCorrectionIsAvailable: Bool = true,
        isAutomationEnabled: Bool
    ) -> Self {
        guard permissionsGranted else { return .missingPermissions }
        guard layoutPairAvailable else { return .layoutPairUnavailable }
        guard languageResourcesAvailable else { return .languageResourcesFailed }
        guard eventMonitorIsOperational else { return .eventMonitorFailed }
        guard automaticCorrectionIsAvailable else { return .automaticCorrectionFailed }
        return isAutomationEnabled ? .ready : .automationOff
    }

    public var menuTitle: String {
        switch self {
        case .missingPermissions:
            "Требуется настройка"
        case .layoutPairUnavailable:
            "Пара раскладок недоступна"
        case .languageResourcesFailed:
            "Языковые ресурсы недоступны"
        case .eventMonitorFailed:
            "Мониторинг ввода недоступен"
        case .automaticCorrectionFailed:
            "Автоматика недоступна"
        case .ready:
            "Готово"
        case .automationOff:
            "Автоматика выключена"
        }
    }

    public var primaryActionTitle: String {
        switch self {
        case .missingPermissions:
            "Выдать разрешения…"
        case .layoutPairUnavailable:
            "Выбрать раскладки…"
        case .languageResourcesFailed:
            "Перезапустить приложение"
        case .eventMonitorFailed:
            "Повторить мониторинг"
        case .automaticCorrectionFailed:
            "Перезапустить приложение"
        case .ready:
            "Выключить автоматику"
        case .automationOff:
            "Включить автоматику"
        }
    }

    public var menuAction: MenuAction {
        switch self {
        case .missingPermissions:
            .openPermissions
        case .layoutPairUnavailable:
            .openSettings
        case .languageResourcesFailed:
            .restartApplication
        case .eventMonitorFailed:
            .restartMonitor
        case .automaticCorrectionFailed:
            .restartApplication
        case .ready, .automationOff:
            .toggleAutomation
        }
    }
}
