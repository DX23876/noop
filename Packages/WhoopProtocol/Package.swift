// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WhoopProtocol",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "WhoopProtocol", targets: ["WhoopProtocol"]),
        .executable(name: "whoop-decode", targets: ["whoop-decode"]),
        .executable(name: "whoop-optical-experiment", targets: ["whoop-optical-experiment"]),
        .executable(name: "whoop-re", targets: ["whoop-re"]),
    ],
    targets: [
        .target(
            name: "WhoopProtocol",
            resources: [.process("Resources/whoop_protocol.json")],
            // Optimised even in Debug — see the note on StrandAnalytics's target. Xcode compiles SPM
            // package targets from the configuration NAME, so `project.yml`'s Debug
            // `SWIFT_OPTIMIZATION_LEVEL: -O` never reached them, and this decode path ran
            // unoptimised in every debug-built run of the app.
            swiftSettings: [.unsafeFlags(["-O"])]
        ),
        .executableTarget(
            name: "whoop-decode",
            dependencies: ["WhoopProtocol"]
        ),
        .executableTarget(
            name: "whoop-optical-experiment",
            dependencies: ["WhoopProtocol"]
        ),
        .executableTarget(
            name: "whoop-re",
            dependencies: ["WhoopProtocol"]
        ),
        .testTarget(
            name: "WhoopProtocolTests",
            dependencies: ["WhoopProtocol"],
            resources: [.process("Resources")]
        ),
    ]
)
