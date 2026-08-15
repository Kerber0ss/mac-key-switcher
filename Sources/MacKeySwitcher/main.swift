import AppKit
import Carbon
import Combine
import ServiceManagement
import SwitcherCore
import SwiftUI
import UniformTypeIdentifiers

let application = NSApplication.shared
private let appDelegate = AppDelegate()
application.setActivationPolicy(.accessory)
application.delegate = appDelegate
application.run()

/// Persists only the fact that the user has read the privacy explanation during
/// first run. It stores a single boolean flag — never any input content.
@MainActor
final class OnboardingStateStore {
    private static let privacyKey = "onboardingPrivacyAcknowledged"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var privacyAcknowledged: Bool {
        defaults.bool(forKey: Self.privacyKey)
    }

    func acknowledgePrivacy() {
        defaults.set(true, forKey: Self.privacyKey)
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var selectedInputSourceObserver: NSObjectProtocol?
    private let permissions = SystemPermissionService()
    private let onboardingState = OnboardingStateStore()
    private let eventSource = CGEventTapSource()
    private let inputSourceCatalog = InputSourceCatalog()
    private let layoutPairStore = LayoutPairStore()
    private let automationSettings = AutomationSettingsStore()
    private let excludedApplications = ExcludedApplicationStore()
    private let eventDeliveryGate = PassiveInputEventDeliveryGate()
    private lazy var inputRuntime = SystemInputRuntime(
        catalog: inputSourceCatalog,
        layoutPairStore: layoutPairStore,
        automationSettings: automationSettings,
        excludedApplications: excludedApplications
    )
    private lazy var monitor = PassiveEventMonitor(
        source: eventSource,
        onEvent: { [weak self, eventDeliveryGate] delivery in
            Task { @MainActor in
                guard let self, eventDeliveryGate.accepts(delivery) else { return }
                self.inputRuntime.receive(delivery.event)
            }
        },
        onFailure: { [weak self] _ in
            // The monitor may report failure from its own executor, so hop to
            // the main actor explicitly instead of assuming isolation.
            Task { @MainActor in
                guard let self else { return }
                self.inputRuntime.closeSession()
                self.refreshPermissionState()
            }
        },
        deliveryGate: eventDeliveryGate
    )
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let stateMenuItem = NSMenuItem()
    private let automationMenuItem = NSMenuItem()
    private let diagnosticsMenuItem = NSMenuItem()
    private let excludeApplicationMenuItem = NSMenuItem()
    /// The exclusion command state captured when the menu opens, so the action
    /// operates on a stable frontmost application rather than re-reading it.
    private var pendingExclusion: FrontmostExclusion = .unavailable

    func applicationDidFinishLaunching(_ notification: Notification) {
        menu.autoenablesItems = false
        menu.delegate = self
        stateMenuItem.target = self
        stateMenuItem.action = #selector(performPrimaryRecovery)
        menu.addItem(stateMenuItem)
        automationMenuItem.target = self
        automationMenuItem.action = #selector(performPrimaryRecovery)
        menu.addItem(automationMenuItem)
        diagnosticsMenuItem.isEnabled = false
        menu.addItem(diagnosticsMenuItem)
        menu.addItem(.separator())
        excludeApplicationMenuItem.target = self
        excludeApplicationMenuItem.action = #selector(excludeCurrentApplication)
        menu.addItem(excludeApplicationMenuItem)
        menu.addItem(.separator())
        let settings = menu.addItem(withTitle: "Открыть настройки…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Выйти", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp

        statusItem.button?.title = "⌨︎"
        statusItem.menu = menu
        selectedInputSourceObserver = DistributedNotificationCenter.default.addObserver(
            forName: Notification.Name("com.apple.Carbon.TISNotifySelectedKeyboardInputSourceChanged"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissionState() }
        }
        refreshPermissionState()
        if !onboardingFlow().isComplete {
            openOnboarding()
        }
    }

    /// The current first-run scenario state, derived from the selected layout
    /// pair, the stored privacy acknowledgement and the live permission snapshot.
    private func onboardingFlow() -> OnboardingFlow {
        inputSourceCatalog.reload()
        return OnboardingFlow(
            layoutPairSelected: layoutPairStore.pair(in: inputSourceCatalog.layouts) != nil,
            privacyAcknowledged: onboardingState.privacyAcknowledged,
            permissions: permissions.snapshot()
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        selectedInputSourceObserver.map(DistributedNotificationCenter.default.removeObserver)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        refreshPermissionState()
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshExcludeApplicationItem()
        refreshPermissionState()
    }

    /// Captures the frontmost application when the menu opens and updates the
    /// "Exclude current application" item accordingly. The bundle ID is captured
    /// here — while this app is not yet frontmost — so the action always targets
    /// the application the user was actually typing in.
    private func refreshExcludeApplicationItem() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        pendingExclusion = FrontmostExclusion.resolve(
            frontmostBundleID: frontmost?.bundleIdentifier,
            ownBundleID: Bundle.main.bundleIdentifier,
            excludedBundleIDs: excludedApplications.userExcludedBundleIDs
        )
        switch pendingExclusion {
        case let .excludable(bundleID):
            let name = frontmost?.localizedName ?? bundleID
            excludeApplicationMenuItem.title = "Исключить «\(name)»"
            excludeApplicationMenuItem.isEnabled = true
        case let .alreadyExcluded(bundleID):
            let name = frontmost?.localizedName ?? bundleID
            excludeApplicationMenuItem.title = "«\(name)» уже исключено"
            excludeApplicationMenuItem.isEnabled = false
        case .unavailable:
            excludeApplicationMenuItem.title = "Исключить текущее приложение"
            excludeApplicationMenuItem.isEnabled = false
        }
    }

    @objc private func excludeCurrentApplication() {
        guard case let .excludable(bundleID) = pendingExclusion else { return }
        excludedApplications.add(bundleID: bundleID)
        refreshExcludeApplicationItem()
        refreshPermissionState()
    }

    @objc private func openSettings() {
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
        } else {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 680, height: 760),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.center()
            window.minSize = NSSize(width: 560, height: 520)
            window.title = "Настройки Mac Key Switcher"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: SettingsView(
                permissions: permissions,
                automationSettings: automationSettings,
                excludedApplications: excludedApplications,
                inputSourceCatalog: inputSourceCatalog,
                layoutPairStore: layoutPairStore,
                currentState: { [weak self] in self?.currentState ?? .initial },
                onPermissionsChanged: refreshPermissionState
            ))
            settingsWindow = window
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openOnboarding() {
        if let onboardingWindow {
            onboardingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "Настройка Mac Key Switcher"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: OnboardingView(
            permissions: permissions,
            onboardingState: onboardingState,
            inputSourceCatalog: inputSourceCatalog,
            layoutPairStore: layoutPairStore,
            currentFlow: { [weak self] in
                self?.onboardingFlow() ?? OnboardingFlow(
                    layoutPairSelected: false,
                    privacyAcknowledged: false,
                    permissions: PermissionSnapshot(listenEventsGranted: false, accessibilityGranted: false)
                )
            },
            onStateChanged: { [weak self] in self?.refreshPermissionState() },
            onFinish: { [weak self] in self?.finishOnboarding() }
        ))
        onboardingWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func finishOnboarding() {
        onboardingWindow?.close()
        onboardingWindow = nil
        refreshPermissionState()
    }

    @objc private func performPrimaryRecovery() {
        switch currentState.menuAction {
        case .openPermissions:
            guard let missingPermission = permissions.snapshot().missingPermissions.first else { return }
            permissions.request(missingPermission)
            permissions.openSystemSettings(for: missingPermission)
        case .openSettings:
            openSettings()
        case .restartApplication:
            NSApp.terminate(nil)
        case .restartMonitor:
            monitor.stop()
            inputRuntime.closeSession()
            monitor.start()
            refreshPermissionState()
        case .toggleAutomation:
            toggleAutomation()
        }
    }

    @objc private func toggleAutomation() {
        let settings = automationSettings.snapshot
        automationSettings.apply(.setAutomationEnabled(!settings.isAutomationEnabled))
        refreshPermissionState()
    }

    private var currentState: ApplicationState {
        inputSourceCatalog.reload()
        return ApplicationState.resolve(
            permissionsGranted: permissions.snapshot().canMonitor,
            layoutPairAvailable: layoutPairStore.pair(in: inputSourceCatalog.layouts) != nil,
            languageResourcesAvailable: LanguageResources.minimum.isUsable,
            eventMonitorIsOperational: monitor.state == .running,
            automaticCorrectionIsAvailable: inputRuntime.automaticCorrectionIsAvailable,
            isAutomationEnabled: automationSettings.snapshot.isAutomationEnabled
        )
    }

    private func refreshPermissionState() {
        let permissionSnapshot = permissions.snapshot()
        if permissionSnapshot.canMonitor {
            monitor.start()
            if monitor.state != .running {
                inputRuntime.closeSession()
            }
        } else {
            monitor.stop()
            inputRuntime.closeSession()
        }
        let state = currentState
        let stateIsRecoveryAction = state != .ready && state != .automationOff
        if stateIsRecoveryAction {
            if stateMenuItem.menu == nil {
                menu.insertItem(stateMenuItem, at: 0)
            }
            if automationMenuItem.menu != nil {
                menu.removeItem(automationMenuItem)
            }
        } else {
            if stateMenuItem.menu != nil {
                menu.removeItem(stateMenuItem)
            }
            if automationMenuItem.menu == nil {
                menu.insertItem(automationMenuItem, at: 0)
            }
        }
        updateInputLanguageIndicator()
        stateMenuItem.title = "Состояние: \(state.menuTitle)"
        stateMenuItem.isEnabled = stateIsRecoveryAction
        stateMenuItem.target = stateIsRecoveryAction ? self : nil
        stateMenuItem.action = stateIsRecoveryAction ? #selector(performPrimaryRecovery) : nil
        automationMenuItem.title = state.primaryActionTitle
        automationMenuItem.isEnabled = state == .ready || state == .automationOff
        diagnosticsMenuItem.title = "Диагностика: \(monitor.state.diagnosticTitle)"
    }

    private func updateInputLanguageIndicator() {
        guard let activeInputSource = inputSourceCatalog.currentInputSource() else {
            statusItem.button?.title = "—"
            statusItem.button?.toolTip = "Текущая раскладка недоступна"
            return
        }
        let indicator: String
        if let pair = layoutPairStore.pair(in: inputSourceCatalog.layouts) {
            switch activeInputSource.id {
            case pair.english.id: indicator = "EN"
            case pair.russian.id: indicator = "RU"
            default: indicator = activeInputSource.name
            }
        } else {
            indicator = activeInputSource.name
        }
        statusItem.button?.title = indicator
        statusItem.button?.toolTip = "Текущая раскладка: \(activeInputSource.name)"
    }
}

/// A single, calm first-run scenario: choose the layout pair, read the privacy
/// contract, then grant the two permissions one at a time, ending with "Готово".
private struct OnboardingView: View {
    let permissions: SystemPermissionService
    let onboardingState: OnboardingStateStore
    let inputSourceCatalog: InputSourceCatalog
    let layoutPairStore: LayoutPairStore
    let currentFlow: () -> OnboardingFlow
    let onStateChanged: () -> Void
    let onFinish: () -> Void

    @State private var flow: OnboardingFlow
    @State private var englishLayoutID = ""
    @State private var russianLayoutID = ""
    @State private var availableLayouts: [KeyboardLayout] = []
    @State private var layoutError: String?

    init(
        permissions: SystemPermissionService,
        onboardingState: OnboardingStateStore,
        inputSourceCatalog: InputSourceCatalog,
        layoutPairStore: LayoutPairStore,
        currentFlow: @escaping () -> OnboardingFlow,
        onStateChanged: @escaping () -> Void,
        onFinish: @escaping () -> Void
    ) {
        self.permissions = permissions
        self.onboardingState = onboardingState
        self.inputSourceCatalog = inputSourceCatalog
        self.layoutPairStore = layoutPairStore
        self.currentFlow = currentFlow
        self.onStateChanged = onStateChanged
        self.onFinish = onFinish
        _flow = State(initialValue: currentFlow())
        _availableLayouts = State(initialValue: inputSourceCatalog.layouts)
        let selected = layoutPairStore.selectedIDs()
        _englishLayoutID = State(initialValue: selected.english)
        _russianLayoutID = State(initialValue: selected.russian)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            Divider()
            stepContent
            Spacer(minLength: 0)
            footer
        }
        .padding(28)
        .frame(width: 560, height: 560, alignment: .topLeading)
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .inputSourceCatalogDidChange)) { _ in
            refresh()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Настройка Mac Key Switcher")
                .font(.title2)
                .accessibilityAddTraits(.isHeader)
            if !flow.isComplete {
                Text("Шаг \(flow.stepNumber) из \(flow.totalSteps)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var stepContent: some View {
        switch flow.step {
        case .chooseLayouts:
            layoutStep
        case .privacy:
            privacyStep
        case .grantListenEvents, .grantAccessibility:
            permissionStep
        case .done:
            doneStep
        }
    }

    private var layoutStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Выберите пару раскладок")
                .font(.headline)
            Text("Укажите две разные системные раскладки — английскую и русскую. Между ними и будет переключать замену.")
                .foregroundStyle(.secondary)
            Picker("Английская", selection: $englishLayoutID) {
                Text("Выберите раскладку").tag("")
                ForEach(availableLayouts) { layout in
                    Text(layout.name).tag(layout.id)
                }
            }
            Picker("Русская", selection: $russianLayoutID) {
                Text("Выберите раскладку").tag("")
                ForEach(availableLayouts) { layout in
                    Text(layout.name).tag(layout.id)
                }
            }
            if let layoutError {
                Text(layoutError)
                    .foregroundStyle(.red)
            }
        }
        .onChange(of: englishLayoutID) { _ in saveLayoutPair() }
        .onChange(of: russianLayoutID) { _ in saveLayoutPair() }
    }

    private var privacyStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Приватность")
                .font(.headline)
            Text("Приложение работает локально и бережно относится к тексту:")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                privacyPoint("Не читает полный текст поля, буфер обмена и сеть не используются.")
                privacyPoint("Перед заменой сверяет лишь короткий фрагмент рядом с курсором.")
                privacyPoint("Никакой телеметрии: введённый текст, символы и хеши не сохраняются.")
                privacyPoint("Любое сомнение — сессия закрывается без изменения текста.")
            }
        }
    }

    private func privacyPoint(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "checkmark.shield")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(text)
        }
    }

    private var permissionStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let permission = flow.pendingPermission {
                Text(permission.title)
                    .font(.headline)
                Text(permission.explanation)
                    .foregroundStyle(.secondary)
                Text("Разрешения запрашиваются по одному. Выдайте это, чтобы продолжить.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
                Text("Готово")
                    .font(.headline)
            }
            Text("Раскладки выбраны, разрешения выданы. Наблюдение за вводом включено, можно печатать.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var footer: some View {
        HStack {
            Spacer()
            switch flow.step {
            case .chooseLayouts:
                Button("Далее") { advance() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!flow.layoutPairSelected)
            case .privacy:
                Button("Понятно, продолжить") {
                    onboardingState.acknowledgePrivacy()
                    advance()
                }
                .keyboardShortcut(.defaultAction)
            case .grantListenEvents, .grantAccessibility:
                if let permission = flow.pendingPermission {
                    Button("Открыть System Settings") {
                        permissions.openSystemSettings(for: permission)
                    }
                    Button("Разрешить") {
                        permissions.request(permission)
                        advance()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            case .done:
                Button("Завершить") { onFinish() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func advance() {
        refresh()
    }

    private func refresh() {
        inputSourceCatalog.reload()
        availableLayouts = inputSourceCatalog.layouts
        let selected = layoutPairStore.selectedIDs()
        if englishLayoutID.isEmpty {
            englishLayoutID = selected.english.isEmpty
                ? availableLayouts.first(where: { $0.id == "com.apple.keylayout.ABC" })?.id ?? ""
                : selected.english
        }
        if russianLayoutID.isEmpty {
            russianLayoutID = selected.russian
        }
        flow = currentFlow()
        onStateChanged()
    }

    private func saveLayoutPair() {
        if layoutPairStore.save(englishID: englishLayoutID, russianID: russianLayoutID, in: availableLayouts) {
            layoutError = nil
            refresh()
        } else if !englishLayoutID.isEmpty || !russianLayoutID.isEmpty {
            layoutError = "Выберите две разные доступные раскладки."
        }
    }
}

private struct SettingsView: View {
    let permissions: SystemPermissionService
    let automationSettings: AutomationSettingsStore
    let excludedApplications: ExcludedApplicationStore
    let inputSourceCatalog: InputSourceCatalog
    let layoutPairStore: LayoutPairStore
    let currentState: () -> ApplicationState
    let onPermissionsChanged: () -> Void
    @State private var snapshot: PermissionSnapshot
    @State private var automation: AutomationSettings
    @State private var applicationState: ApplicationState
    @State private var exceptionDraft = ""
    @State private var excludedBundleIDs: Set<String>
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var englishLayoutID = ""
    @State private var russianLayoutID = ""
    @State private var availableLayouts: [KeyboardLayout] = []
    @State private var layoutPairError: String?

    init(
        permissions: SystemPermissionService,
        automationSettings: AutomationSettingsStore,
        excludedApplications: ExcludedApplicationStore,
        inputSourceCatalog: InputSourceCatalog,
        layoutPairStore: LayoutPairStore,
        currentState: @escaping () -> ApplicationState,
        onPermissionsChanged: @escaping () -> Void
    ) {
        self.permissions = permissions
        self.automationSettings = automationSettings
        self.excludedApplications = excludedApplications
        self.inputSourceCatalog = inputSourceCatalog
        self.layoutPairStore = layoutPairStore
        self.currentState = currentState
        self.onPermissionsChanged = onPermissionsChanged
        _snapshot = State(initialValue: permissions.snapshot())
        _automation = State(initialValue: automationSettings.snapshot)
        _applicationState = State(initialValue: currentState())
        _excludedBundleIDs = State(initialValue: excludedApplications.userExcludedBundleIDs)
        let selected = layoutPairStore.selectedIDs()
        _englishLayoutID = State(initialValue: selected.english)
        _russianLayoutID = State(initialValue: selected.russian)
        _availableLayouts = State(initialValue: inputSourceCatalog.layouts)
    }

    var body: some View {
        Form {
            statusSection
            permissionsSection
            layoutsSection
            automationSection
            wordExceptionsSection
            excludedApplicationsSection
        }
        .formStyle(.grouped)
        .navigationTitle("Mac Key Switcher")
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            snapshot = permissions.snapshot()
            applicationState = currentState()
        }
        .onReceive(NotificationCenter.default.publisher(for: .inputSourceCatalogDidChange)) { _ in
            refreshLayouts()
            applicationState = currentState()
        }
        .onChange(of: englishLayoutID) { _ in saveLayoutPair() }
        .onChange(of: russianLayoutID) { _ in saveLayoutPair() }
        .frame(minWidth: 560, minHeight: 520)
    }

    private var statusSection: some View {
        Section("Состояние") {
            LabeledContent("Текущее состояние") {
                Label(applicationState.menuTitle, systemImage: statusSymbol)
                    .foregroundStyle(statusIsHealthy ? Color.green : Color.orange)
                    .labelStyle(.titleAndIcon)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(
                        "Текущее состояние: \(applicationState.menuTitle). "
                            + (statusIsHealthy ? "Работает нормально." : "Требуется внимание.")
                    )
            }
        }
    }

    private var statusIsHealthy: Bool {
        applicationState == .ready || applicationState == .automationOff
    }

    private var statusSymbol: String {
        statusIsHealthy ? "checkmark.circle" : "exclamationmark.triangle"
    }

    private var permissionsSection: some View {
        Section("Разрешения") {
            if snapshot.canMonitor {
                Label("Все нужные разрешения выданы. Наблюдение за вводом включено.", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Все нужные разрешения выданы. Наблюдение за вводом включено.")
            } else {
                ForEach(snapshot.missingPermissions, id: \.self) { permission in
                    VStack(alignment: .leading, spacing: 6) {
                        Label(permission.title, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Text(permission.explanation)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Разрешить") {
                                permissions.request(permission)
                                refresh()
                            }
                            .accessibilityLabel("Разрешить: \(permission.title)")
                            Button("Открыть System Settings") {
                                permissions.openSystemSettings(for: permission)
                            }
                            .accessibilityLabel("Открыть System Settings для: \(permission.title)")
                        }
                    }
                    .padding(.vertical, 2)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Не выдано разрешение: \(permission.title). \(permission.explanation)")
                }
            }
        }
    }

    private var layoutsSection: some View {
        Section("Раскладки") {
            Picker("Английская", selection: $englishLayoutID) {
                Text("Выберите раскладку").tag("")
                ForEach(availableLayouts) { layout in
                    Text(layout.name).tag(layout.id)
                }
            }
            Picker("Русская", selection: $russianLayoutID) {
                Text("Выберите раскладку").tag("")
                ForEach(availableLayouts) { layout in
                    Text(layout.name).tag(layout.id)
                }
            }
            if let layoutPairError {
                Label(layoutPairError, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Ошибка раскладок: \(layoutPairError)")
            }
            Text("Выберите две разные системные раскладки. Ручная команда меняет последнее или текущее слово в безопасном поле.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var automationSection: some View {
        Section("Автоматика") {
            Toggle("Автоматика", isOn: Binding(
                get: { automation.isAutomationEnabled },
                set: { setAutomationEnabled($0) }
            ))
            LabeledContent("Ручная конвертация") {
                HStack {
                    ShortcutRecorder(shortcut: automation.manualConversionShortcut) { shortcut in
                        setManualConversionShortcut(shortcut)
                    }
                    .accessibilityLabel("Записать сочетание для ручной конвертации")
                    .accessibilityValue(automation.manualConversionShortcut.displayName)
                    Button("Double Shift") {
                        setManualConversionShortcut(.doubleShift)
                    }
                    .disabled(automation.manualConversionShortcut == .doubleShift)
                    .accessibilityLabel("Сбросить сочетание на Double Shift")
                }
            }
            Text("Нажмите поле и затем нужную клавишу или сочетание. По умолчанию — Double Shift. Ручная конвертация доступна и когда автоматика выключена.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Toggle("Запускать при входе", isOn: Binding(
                get: { launchAtLogin },
                set: { setLaunchAtLogin($0) }
            ))
            Text("Используется системный механизм macOS без отдельного helper-процесса.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var wordExceptionsSection: some View {
        Section("Словесные исключения") {
            HStack {
                TextField("Написание", text: $exceptionDraft)
                    .accessibilityLabel("Новое словесное исключение")
                Button("Добавить", action: addException)
                    .disabled(normalizedWordException(exceptionDraft) == nil)
                    .accessibilityLabel("Добавить словесное исключение")
            }
            ForEach(automation.wordExceptions.sorted(), id: \.self) { exception in
                HStack {
                    Text(exception)
                    Spacer()
                    Button("Удалить") { removeException(exception) }
                        .accessibilityLabel("Удалить исключение «\(exception)»")
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var excludedApplicationsSection: some View {
        Section("Исключённые приложения") {
            Button("Выбрать приложения…", action: chooseExcludedApplications)
                .accessibilityLabel("Выбрать приложения для исключения")
            ForEach(excludedBundleIDs.sorted(), id: \.self) { bundleID in
                HStack {
                    Text(applicationTitle(for: bundleID))
                    Spacer()
                    Button("Удалить") { removeExcludedApplication(bundleID) }
                        .accessibilityLabel("Убрать «\(applicationTitle(for: bundleID))» из исключений")
                }
                .accessibilityElement(children: .combine)
            }
            Text("В этих приложениях автоматика отключена; ручная конвертация остаётся доступна только в безопасном поле.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func refresh() {
        snapshot = permissions.snapshot()
        automation = automationSettings.snapshot
        excludedBundleIDs = excludedApplications.userExcludedBundleIDs
        inputSourceCatalog.reload()
        refreshLayouts()
        let selected = layoutPairStore.selectedIDs()
        englishLayoutID = selected.english.isEmpty
            ? availableLayouts.first(where: { $0.id == "com.apple.keylayout.ABC" })?.id ?? ""
            : selected.english
        russianLayoutID = selected.russian
        launchAtLogin = SMAppService.mainApp.status == .enabled
        applicationState = currentState()
        onPermissionsChanged()
    }

    private func setLaunchAtLogin(_ isEnabled: Bool) {
        do {
            if isEnabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func setAutomationEnabled(_ isEnabled: Bool) {
        automation = automationSettings.apply(.setAutomationEnabled(isEnabled))
        applicationState = currentState()
        onPermissionsChanged()
    }

    private func setManualConversionShortcut(_ shortcut: ManualConversionShortcut) {
        automation = automationSettings.apply(.setManualConversionShortcut(shortcut))
        onPermissionsChanged()
    }

    private func addException() {
        automation = automationSettings.apply(.addWordException(exceptionDraft))
        exceptionDraft = ""
        onPermissionsChanged()
    }

    private func removeException(_ exception: String) {
        automation = automationSettings.apply(.removeWordException(exception))
        onPermissionsChanged()
    }

    private func chooseExcludedApplications() {
        let panel = NSOpenPanel()
        panel.title = "Выберите исключённые приложения"
        panel.message = "Для выбора нескольких приложений удерживайте ⌘."
        panel.prompt = "Добавить"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.applicationBundle]

        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK else { return }
            panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }.forEach {
                excludedApplications.add(bundleID: $0)
            }
            refresh()
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    private func removeExcludedApplication(_ bundleID: String) {
        excludedApplications.remove(bundleID: bundleID)
        refresh()
    }

    private func applicationTitle(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return bundleID
        }
        let name = Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? url.deletingPathExtension().lastPathComponent
        return "\(name) (\(bundleID))"
    }

    private func saveLayoutPair() {
        if layoutPairStore.save(englishID: englishLayoutID, russianID: russianLayoutID, in: availableLayouts) {
            layoutPairError = nil
            onPermissionsChanged()
        } else if !englishLayoutID.isEmpty || !russianLayoutID.isEmpty {
            layoutPairError = "Выберите две разные доступные раскладки."
        }
    }

    private func refreshLayouts() {
        availableLayouts = inputSourceCatalog.layouts
    }
}

private struct ShortcutRecorder: NSViewRepresentable {
    let shortcut: ManualConversionShortcut
    let onRecord: (ManualConversionShortcut) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let button = ShortcutRecorderButton()
        button.onRecord = onRecord
        button.shortcut = shortcut
        return button
    }

    func updateNSView(_ button: ShortcutRecorderButton, context: Context) {
        button.onRecord = onRecord
        button.shortcut = shortcut
    }
}

private final class ShortcutRecorderButton: NSButton {
    var onRecord: ((ManualConversionShortcut) -> Void)?
    var shortcut: ManualConversionShortcut = .doubleShift {
        didSet {
            title = shortcut.displayName
            setAccessibilityValue(shortcut.displayName)
        }
    }

    override var acceptsFirstResponder: Bool { true }

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryChange)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Записать сочетание для ручной конвертации")
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        title = "Нажмите сочетание…"
        setAccessibilityValue("Ожидание ввода сочетания")
    }

    override func keyDown(with event: NSEvent) {
        record(keyCode: UInt16(event.keyCode), modifierFlags: event.modifierFlags)
    }

    override func flagsChanged(with event: NSEvent) {
        guard UInt16(event.keyCode) == UInt16(kVK_CapsLock) else {
            super.flagsChanged(with: event)
            return
        }
        record(keyCode: UInt16(event.keyCode), modifierFlags: event.modifierFlags)
    }

    private func record(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) {
        let flags = modifierFlags.intersection([.shift, .control, .option, .command]).rawValue
        onRecord?(.key(keyCode: keyCode, modifierFlags: UInt64(flags)))
    }
}

private extension ManualConversionShortcut {
    var displayName: String {
        switch self {
        case .doubleShift:
            return "Double Shift"
        case let .key(keyCode, modifierFlags):
            let modifiers = [
                (UInt64(NSEvent.ModifierFlags.control.rawValue), "⌃"),
                (UInt64(NSEvent.ModifierFlags.option.rawValue), "⌥"),
                (UInt64(NSEvent.ModifierFlags.shift.rawValue), "⇧"),
                (UInt64(NSEvent.ModifierFlags.command.rawValue), "⌘"),
            ].compactMap { modifierFlags & $0.0 != 0 ? $0.1 : nil }.joined()
            return modifiers + keyName(for: keyCode)
        }
    }

    private func keyName(for keyCode: UInt16) -> String {
        switch keyCode {
        case UInt16(kVK_CapsLock): "Caps Lock"
        case UInt16(kVK_F1): "F1"
        case UInt16(kVK_F2): "F2"
        case UInt16(kVK_F3): "F3"
        case UInt16(kVK_F4): "F4"
        case UInt16(kVK_F5): "F5"
        case UInt16(kVK_F6): "F6"
        case UInt16(kVK_F7): "F7"
        case UInt16(kVK_F8): "F8"
        case UInt16(kVK_F9): "F9"
        case UInt16(kVK_F10): "F10"
        case UInt16(kVK_F11): "F11"
        case UInt16(kVK_F12): "F12"
        case UInt16(kVK_Space): "Пробел"
        case UInt16(kVK_Return): "Return"
        case UInt16(kVK_Tab): "Tab"
        case UInt16(kVK_Escape): "Esc"
        default: "Клавиша \(keyCode)"
        }
    }
}

private extension PassiveEventMonitorState {
    var diagnosticTitle: String {
        switch self {
        case .stopped:
            "монитор выключен"
        case .running:
            "монитор listen-only активен"
        case .recovering:
            "монитор восстанавливается"
        case .failed:
            "монитор недоступен"
        }
    }
}
