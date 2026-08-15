// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacKeySwitcher",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "MacKeySwitcher", targets: ["MacKeySwitcher"]),
        .library(name: "SwitcherCore", targets: ["SwitcherCore"]),
    ],
    targets: [
        .target(
            name: "SwitcherCore",
            resources: [.copy("Resources/LanguageDetector/v2-word-ranks.tsv")]
        ),
        .executableTarget(
            name: "MacKeySwitcher",
            dependencies: ["SwitcherCore"],
            linkerSettings: [.linkedFramework("Carbon")]
        ),
        .testTarget(name: "SwitcherCoreTests", dependencies: ["SwitcherCore"]),
    ]
)
