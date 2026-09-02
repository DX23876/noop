// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "EnergyBench",
    platforms: [.macOS(.v13)],
    dependencies: [.package(path: "../../Packages/StrandAnalytics")],
    targets: [
        .executableTarget(
            name: "energybench",
            dependencies: [.product(name: "StrandAnalytics", package: "StrandAnalytics")]),
    ])
