// swift-tools-version:5.9
import PackageDescription

let strict: [SwiftSetting] = [.enableExperimentalFeature("StrictConcurrency")]

let package = Package(
    name: "AgentBarCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AgentBarCore", targets: ["AgentBarCore"]),
        .executable(name: "agentbar", targets: ["agentbar"]),
    ],
    targets: [
        .target(name: "AgentBarCore", swiftSettings: strict),
        // CLI: standalone (Foundation only), no dependency on the core library.
        .executableTarget(name: "agentbar", swiftSettings: strict),
        // Test host used by Tests/e2e.sh: runs store + server in a temp dir without GUI.
        .executableTarget(name: "agentbar-testhost", dependencies: ["AgentBarCore"],
                          path: "Tests/agentbar-testhost", swiftSettings: strict),
        .testTarget(name: "AgentBarCoreTests", dependencies: ["AgentBarCore"],
                    path: "Tests/AgentBarCoreTests", swiftSettings: strict),
    ]
)
