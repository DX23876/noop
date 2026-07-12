// swift-tools-version: 5.9
import PackageDescription

// Clean-room Polar Measurement Data (PMD) BLE protocol package. Mirrors the layout of
// Packages/OuraProtocol / Packages/WhoopProtocol: a pure value-type library target (zero CoreBluetooth,
// headless/JVM-testable) plus a test target. The live CoreBluetooth source that feeds this decoder (a
// `PolarPMDSource: LiveHRSource`) is an app-target follow-up; this package is the wire-level decode only,
// so it builds and tests on Linux/CI with no strap.
let package = Package(
    name: "PolarProtocol",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "PolarProtocol", targets: ["PolarProtocol"]),
    ],
    targets: [
        .target(
            name: "PolarProtocol"
        ),
        .testTarget(
            name: "PolarProtocolTests",
            dependencies: ["PolarProtocol"]
        ),
    ]
)
