// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "StrandTraining",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "StrandTraining", targets: ["StrandTraining"])],
    targets: [
        .target(name: "StrandTraining", swiftSettings: [.unsafeFlags(["-O"])]),
        .testTarget(name: "StrandTrainingTests", dependencies: ["StrandTraining"]),
    ]
)
