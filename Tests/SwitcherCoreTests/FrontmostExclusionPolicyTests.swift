import XCTest
@testable import SwitcherCore

final class FrontmostExclusionPolicyTests: XCTestCase {
    func testValidNotExcludedFrontmostIsExcludable() {
        let result = FrontmostExclusion.resolve(
            frontmostBundleID: "com.apple.TextEdit",
            ownBundleID: "com.example.MacKeySwitcher",
            excludedBundleIDs: []
        )

        XCTAssertEqual(result, .excludable(bundleID: "com.apple.TextEdit"))
    }

    func testAlreadyExcludedFrontmostReportsAlreadyExcluded() {
        let result = FrontmostExclusion.resolve(
            frontmostBundleID: "com.example.Editor",
            ownBundleID: "com.example.MacKeySwitcher",
            excludedBundleIDs: ["com.example.Editor"]
        )

        XCTAssertEqual(result, .alreadyExcluded(bundleID: "com.example.Editor"))
    }

    func testOwnApplicationIsNeverExcludable() {
        let result = FrontmostExclusion.resolve(
            frontmostBundleID: "com.example.MacKeySwitcher",
            ownBundleID: "com.example.MacKeySwitcher",
            excludedBundleIDs: []
        )

        XCTAssertEqual(result, .unavailable)
    }

    func testNilFrontmostBundleIDIsUnavailable() {
        let result = FrontmostExclusion.resolve(
            frontmostBundleID: nil,
            ownBundleID: "com.example.MacKeySwitcher",
            excludedBundleIDs: []
        )

        XCTAssertEqual(result, .unavailable)
    }

    func testInvalidFrontmostBundleIDIsUnavailable() {
        let result = FrontmostExclusion.resolve(
            frontmostBundleID: "Not A Bundle ID",
            ownBundleID: "com.example.MacKeySwitcher",
            excludedBundleIDs: []
        )

        XCTAssertEqual(result, .unavailable)
    }

    func testResolveNeverMutatesTheExcludedSet() {
        let excluded: Set<String> = ["com.example.Editor"]

        _ = FrontmostExclusion.resolve(
            frontmostBundleID: "com.apple.TextEdit",
            ownBundleID: "com.example.MacKeySwitcher",
            excludedBundleIDs: excluded
        )

        XCTAssertEqual(excluded, ["com.example.Editor"])
    }
}
