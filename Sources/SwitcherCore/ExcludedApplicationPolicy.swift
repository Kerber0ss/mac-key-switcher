import Foundation

/// Safety of the focused input context, as confirmed by the platform boundary.
public enum ApplicationInputContext: Sendable, Equatable {
    case supported
    case protected
    case unknown
}

/// A local application policy. It uses only the focused application's bundle identifier.
public struct ExcludedApplicationPolicy: Sendable, Equatable {
    private let excludedBundleIDs: Set<String>
    private let revision: UInt64

    public init(userExcludedBundleIDs: Set<String> = [], revision: UInt64 = 0) {
        excludedBundleIDs = userExcludedBundleIDs.filter(ExcludedApplicationStore.isValid)
        self.revision = revision
    }

    public func permissions(for bundleID: String?, context: ApplicationInputContext) -> InputPolicySnapshot {
        guard context != .protected else {
            return .init(allowsAutomaticCorrection: false, allowsManualConversion: false, revision: revision)
        }
        return .init(
            allowsAutomaticCorrection: bundleID.map { !excludedBundleIDs.contains($0) } ?? false,
            allowsManualConversion: true,
            revision: revision
        )
    }
}

/// Persists only user-supplied concrete bundle identifiers; application names are never classified.
public final class ExcludedApplicationStore: @unchecked Sendable {
    private static let key = "excludedApplicationBundleIDs"

    private let defaults: UserDefaults
    private var revision: UInt64 = 0

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var userExcludedBundleIDs: Set<String> {
        Set(defaults.stringArray(forKey: Self.key) ?? [])
    }

    public func add(bundleID: String) {
        guard Self.isValid(bundleID) else { return }
        save(userExcludedBundleIDs.union([bundleID]))
    }

    public func remove(bundleID: String) {
        save(userExcludedBundleIDs.subtracting([bundleID]))
    }

    public func policy() -> ExcludedApplicationPolicy {
        .init(userExcludedBundleIDs: userExcludedBundleIDs, revision: revision)
    }

    public static func isValid(_ bundleID: String) -> Bool {
        let labels = bundleID.split(separator: ".", omittingEmptySubsequences: false)
        return labels.count >= 2 && labels.allSatisfy { label in
            !label.isEmpty && label.unicodeScalars.allSatisfy {
                (48 ... 57).contains($0.value) || (65 ... 90).contains($0.value) ||
                    (97 ... 122).contains($0.value) || $0.value == 45
            }
        }
    }

    private func save(_ bundleIDs: Set<String>) {
        guard bundleIDs != userExcludedBundleIDs else { return }
        defaults.set(bundleIDs.sorted(), forKey: Self.key)
        revision &+= 1
    }
}
