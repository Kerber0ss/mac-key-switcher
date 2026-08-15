import Foundation
import XCTest

final class PrivacyBoundaryAuditTests: XCTestCase {
    func testReleaseSourcesContainNoNetworkClientOrClipboardAPIs() throws {
        let prohibitedAPIs = [
            "import Network", "import CFNetwork", "URLSession", "URLRequest", "WebSocket",
            "NWConnection", "NWListener", "NSPasteboard", "UIPasteboard", "pbcopy", "curl ", "wget ",
        ]

        for source in try releaseSources() {
            let contents = try String(contentsOf: source, encoding: .utf8)
            for api in prohibitedAPIs {
                XCTAssertFalse(contents.contains(api), "\(source.lastPathComponent) must not use \(api)")
            }
        }
    }

    func testDetectorUsesOnlyDocumentedBundledWordResources() throws {
        let detector = try String(
            contentsOf: repositoryRoot.appending(path: "Sources/SwitcherCore/LanguageDetector.swift"),
            encoding: .utf8
        )
        let runtime = try String(
            contentsOf: repositoryRoot.appending(path: "Sources/MacKeySwitcher/SystemInputRuntime.swift"),
            encoding: .utf8
        )
        let attribution = try String(
            contentsOf: repositoryRoot.appending(path: "Resources/LanguageDetector/source/ATTRIBUTION.md"),
            encoding: .utf8
        )

        XCTAssertFalse(detector.contains("isKnownWordOutsideResources"))
        for prohibitedSource in ["NSSpellChecker", "SystemWordDictionary"] {
            XCTAssertFalse(runtime.contains(prohibitedSource), "Release detector must not use \(prohibitedSource).")
        }
        XCTAssertTrue(attribution.contains("complete release-time word evidence"))
        XCTAssertTrue(attribution.contains("FrequencyWords"))
        XCTAssertTrue(attribution.contains("CC BY-SA 4.0"))
    }

    func testReleaseDiagnosticsHaveNoInputContentOrHashSink() throws {
        let appSource = try String(contentsOf: repositoryRoot.appending(path: "Sources/MacKeySwitcher/main.swift"), encoding: .utf8)
        XCTAssertTrue(appSource.contains("diagnosticsMenuItem"), "Keep this audit tied to the release diagnostic surface.")

        for prohibitedFragment in [
            "InputSessionToken", "FocusInspection", "localTextBeforeCursor", "typed", "candidate",
            "hash", "Logger", "OSLog", "os_log", "NSLog", "print(",
        ] {
            XCTAssertFalse(appSource.contains(prohibitedFragment), "Release diagnostics must not contain \(prohibitedFragment).")
        }
    }

    func testEventCallbackAcceptsOnlyMetadataAndDefersFailureRecovery() throws {
        let monitorSource = try String(contentsOf: repositoryRoot.appending(path: "Sources/MacKeySwitcher/SystemInputMonitoring.swift"), encoding: .utf8)
        let callback = try XCTUnwrap(monitorSource.components(separatedBy: "private func eventTapCallback").dropFirst().first)
        let failureReport = try XCTUnwrap(monitorSource.components(separatedBy: "fileprivate func report").dropFirst().first)

        XCTAssertTrue(failureReport.contains("DispatchQueue.main.async"))
        XCTAssertTrue(callback.contains("source.normalize"))
        for prohibitedFragment in ["AX", "Task", "await", "NSPasteboard", "CGEvent.post"] {
            XCTAssertFalse(callback.contains(prohibitedFragment), "Event callback must not perform \(prohibitedFragment).")
        }

        let eventDefinition = try String(contentsOf: repositoryRoot.appending(path: "Sources/SwitcherCore/PassiveEventMonitor.swift"), encoding: .utf8)
        let eventSection = try XCTUnwrap(eventDefinition.components(separatedBy: "public struct PassiveInputEvent").dropFirst().first?.components(separatedBy: "/// The system boundary").first)
        XCTAssertFalse(eventSection.contains("String"), "The event boundary must not carry typed text.")
        XCTAssertFalse(eventSection.contains("Character"), "The event boundary must not carry typed characters.")
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func releaseSources() throws -> [URL] {
        let directory = repositoryRoot.appending(path: "Sources")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil))
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }
}
