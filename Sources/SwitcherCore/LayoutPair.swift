/// Системная Keyboard Layout, пригодная для назначения языковой роли.
public struct KeyboardLayout: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// Выбранные пользователем английская и русская системные раскладки.
public struct LayoutPair: Equatable, Sendable {
    public let english: KeyboardLayout
    public let russian: KeyboardLayout

    public static func select(
        englishID: String?,
        russianID: String?,
        from availableLayouts: [KeyboardLayout]
    ) -> Result<Self, LayoutPairValidationError> {
        guard let englishID, let russianID else { return .failure(.incomplete) }
        guard englishID != russianID else { return .failure(.sameLayout) }
        guard
            let english = availableLayouts.first(where: { $0.id == englishID }),
            let russian = availableLayouts.first(where: { $0.id == russianID })
        else {
            return .failure(.unavailable)
        }
        return .success(Self(english: english, russian: russian))
    }

    public func availability(in availableLayouts: [KeyboardLayout]) -> LayoutPairAvailability {
        let availableIDs = Set(availableLayouts.map(\.id))
        return availableIDs.contains(english.id) && availableIDs.contains(russian.id) ? .available : .unavailable
    }
}

public enum LayoutPairValidationError: Error, Equatable, Sendable {
    case incomplete
    case sameLayout
    case unavailable
}

public enum LayoutPairAvailability: Equatable, Sendable {
    case available
    case unavailable
}

/// Физическое нажатие, из которого обе раскладки получают символ независимо друг от друга.
public struct KeyStroke: Equatable, Sendable {
    public struct Modifiers: OptionSet, Equatable, Sendable {
        public let rawValue: UInt8

        public init(rawValue: UInt8) {
            self.rawValue = rawValue
        }

        public static let shift = Self(rawValue: 1 << 0)
        public static let capsLock = Self(rawValue: 1 << 1)
    }

    public let keyCode: UInt16
    public let modifiers: Modifiers

    public init(keyCode: UInt16, modifiers: Modifiers = []) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

/// Чистое преобразование KeyStroke в кандидата на другой стороне выбранной пары.
public struct LayoutPairConverter: Sendable {
    public typealias Translate = @Sendable (KeyboardLayout, KeyStroke) -> String?

    private let pair: LayoutPair
    private let translate: Translate

    public init(pair: LayoutPair, translate: @escaping Translate) {
        self.pair = pair
        self.translate = translate
    }

    public func candidate(for keyStroke: KeyStroke, activeLayoutID: String) -> String? {
        let target: KeyboardLayout
        switch activeLayoutID {
        case pair.english.id: target = pair.russian
        case pair.russian.id: target = pair.english
        default: return nil
        }
        return translate(target, keyStroke)
    }
}
