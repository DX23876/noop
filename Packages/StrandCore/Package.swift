// swift-tools-version:5.9
import PackageDescription

// The platform-neutral core shared by the Apple apps and Android (docs/fork/android/PLAN.md, phase B).
// It drives the packages below: the daily analysis pass, the data functions it needs, backup format work
// and raw collection move here from the app target in the order of docs/fork/android/INVENTORY.md.
// No SwiftUI, no Combine, no StrandDesign: everything here must also build for Android. ZIPFoundation (through
// StrandImport) needs a carried patch there, like GRDB (docs/fork/android/STATUS.md, known deviations).
let package = Package(
    name: "StrandCore",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [.library(name: "StrandCore", targets: ["StrandCore"])],
    dependencies: [
        .package(path: "../WhoopProtocol"),
        .package(path: "../WhoopStore"),
        .package(path: "../StrandAnalytics"),
        .package(path: "../StrandTraining"),
        .package(path: "../StrandImport"),
        // Pinned EXACT, the same versions as every other package and project.yml, so SPM resolves one copy.
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "6.29.3"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20"),
    ],
    targets: [
        .target(
            name: "StrandCore",
            dependencies: ["WhoopProtocol", "WhoopStore", "StrandAnalytics", "StrandTraining", "StrandImport",
                           .product(name: "GRDB", package: "GRDB.swift"),
                           .product(name: "ZIPFoundation", package: "ZIPFoundation")],
            // Optimised even in Debug, like StrandAnalytics and WhoopStore: Xcode compiles package
            // targets from the configuration name, so project.yml's Debug `-O` never reaches them.
            swiftSettings: [.unsafeFlags(["-O"])]),
        .testTarget(name: "StrandCoreTests", dependencies: ["StrandCore", "WhoopStore", "StrandAnalytics", "StrandTraining"]),
    ]
)
