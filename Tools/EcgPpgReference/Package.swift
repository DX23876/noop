// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "EcgPpgReference",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "../../Packages/WhoopStore"),
        .package(path: "../../Packages/StrandAnalytics"),
        .package(path: "../../Packages/WhoopProtocol"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.3"),
    ],
    targets: [.executableTarget(name: "rr-reference-export", dependencies: [
        "WhoopStore", "StrandAnalytics", "WhoopProtocol",
        .product(name: "GRDB", package: "GRDB.swift"),
    ], path: "RRExport")]
)
