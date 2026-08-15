import Foundation

/// A pure decision helper for the "Exclude current application" menu command.
///
/// It classifies whether the frontmost application's bundle identifier can be
/// added to the user exclusion set. It never mutates state and never creates an
/// exclusion on its own — the caller performs the write only for the
/// `.excludable` case. Following the project pattern (`ShiftFlagsDecoder`,
/// `AXValueCasting`, `TechnicalToken`), the logic lives in `SwitcherCore` so it
/// is unit-testable without AppKit.
public enum FrontmostExclusion: Sendable, Equatable {
    /// The frontmost bundle ID is valid, is not this app, and is not yet
    /// excluded. `bundleID` is the concrete identifier to add.
    case excludable(bundleID: String)
    /// The frontmost bundle ID is already in the user exclusion set.
    case alreadyExcluded(bundleID: String)
    /// There is no eligible frontmost application: no bundle ID, an invalid
    /// bundle ID, or the frontmost application is this switcher itself.
    case unavailable

    /// Resolves the exclusion command state from the current environment.
    ///
    /// - Parameters:
    ///   - frontmostBundleID: The bundle identifier of the frontmost
    ///     application, or `nil` when it cannot be determined.
    ///   - ownBundleID: This application's own bundle identifier, so it never
    ///     excludes itself.
    ///   - excludedBundleIDs: The current user exclusion set.
    public static func resolve(
        frontmostBundleID: String?,
        ownBundleID: String?,
        excludedBundleIDs: Set<String>
    ) -> FrontmostExclusion {
        guard let bundleID = frontmostBundleID,
              ExcludedApplicationStore.isValid(bundleID),
              bundleID != ownBundleID
        else {
            return .unavailable
        }
        if excludedBundleIDs.contains(bundleID) {
            return .alreadyExcluded(bundleID: bundleID)
        }
        return .excludable(bundleID: bundleID)
    }
}
