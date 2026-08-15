import Carbon
import Foundation
import SwitcherCore

extension Notification.Name {
    static let inputSourceCatalogDidChange = Self("MacKeySwitcher.inputSourceCatalogDidChange")
}

struct SystemKeyboardLayout {
    let layout: KeyboardLayout
    let unicodeLayoutData: Data
}

/// Снимок включённых Keyboard Layout с Unicode-данными. Обновляется при открытии настроек и системном изменении источников.
@MainActor
final class InputSourceCatalog {
    private(set) var systemLayouts: [SystemKeyboardLayout] = []
    private var inputSourceObserver: NSObjectProtocol?

    var layouts: [KeyboardLayout] {
        systemLayouts.map(\.layout)
    }

    init() {
        reload()
        inputSourceObserver = DistributedNotificationCenter.default.addObserver(
            forName: Notification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    func reload() {
        let filter = [kTISPropertyInputSourceType as String: kTISTypeKeyboardLayout] as CFDictionary
        let sources = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] ?? []
        systemLayouts = sources.compactMap(Self.systemLayout)
        NotificationCenter.default.post(name: .inputSourceCatalogDidChange, object: self)
    }

    func converter(for pair: LayoutPair) -> LayoutPairConverter {
        let dataByID = Dictionary(uniqueKeysWithValues: systemLayouts.map { ($0.layout.id, $0.unicodeLayoutData) })
        return LayoutPairConverter(pair: pair) { layout, keyStroke in
            guard let data = dataByID[layout.id] else { return nil }
            return Self.translate(keyStroke, with: data)
        }
    }

    func output(for keyStroke: KeyStroke, in layoutID: String) -> String? {
        guard let layout = systemLayouts.first(where: { $0.layout.id == layoutID }) else { return nil }
        return Self.translate(keyStroke, with: layout.unicodeLayoutData)
    }

    func currentLayoutID() -> String? {
        currentInputSource().map(\.id)
    }

    func currentInputSource() -> KeyboardLayout? {
        guard
            let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
            let idPointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID),
            let namePointer = TISGetInputSourceProperty(source, kTISPropertyLocalizedName)
        else { return nil }
        return .init(
            id: Unmanaged<CFString>.fromOpaque(idPointer).takeUnretainedValue() as String,
            name: Unmanaged<CFString>.fromOpaque(namePointer).takeUnretainedValue() as String
        )
    }

    /// Selecting an input source only calls the thread-safe TIS C APIs and
    /// touches no catalog instance state, so it is `nonisolated`. This lets the
    /// input-source service switch layouts on whatever executor drives the
    /// monitor lifecycle without the fragile `MainActor.assumeIsolated`.
    nonisolated func select(layoutID: String) -> Bool {
        let filter = [kTISPropertyInputSourceID as String: layoutID] as CFDictionary
        guard
            let sources = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource],
            let source = sources.first
        else { return false }
        return TISSelectInputSource(source) == noErr
    }

    nonisolated private static func systemLayout(_ source: TISInputSource) -> SystemKeyboardLayout? {
        guard
            let idPointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID),
            let namePointer = TISGetInputSourceProperty(source, kTISPropertyLocalizedName),
            let dataPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else {
            return nil
        }
        let id = Unmanaged<CFString>.fromOpaque(idPointer).takeUnretainedValue() as String
        let name = Unmanaged<CFString>.fromOpaque(namePointer).takeUnretainedValue() as String
        let data = Unmanaged<CFData>.fromOpaque(dataPointer).takeUnretainedValue() as Data
        return SystemKeyboardLayout(layout: KeyboardLayout(id: id, name: name), unicodeLayoutData: data)
    }

    nonisolated private static func translate(_ keyStroke: KeyStroke, with data: Data) -> String? {
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let modifiers = modifierState(for: keyStroke.modifiers)

        let status = data.withUnsafeBytes { bytes in
            UCKeyTranslate(
                bytes.baseAddress!.assumingMemoryBound(to: UCKeyboardLayout.self),
                keyStroke.keyCode,
                UInt16(kUCKeyActionDown),
                modifiers,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysMask),
                &deadKeyState,
                characters.count,
                &length,
                &characters
            )
        }
        guard status == noErr, deadKeyState == 0, length == 1 else { return nil }
        return String(utf16CodeUnits: characters, count: Int(length))
    }

    nonisolated private static func modifierState(for modifiers: KeyStroke.Modifiers) -> UInt32 {
        var state: UInt32 = 0
        if modifiers.contains(.shift) { state |= UInt32(shiftKey) >> 8 }
        if modifiers.contains(.capsLock) { state |= UInt32(alphaLock) >> 8 }
        return state
    }
}
