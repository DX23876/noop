// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SemanticMemory",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "SemanticMemory", targets: ["SemanticMemory"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "6.29.3"),
    ],
    targets: [
        .target(
            name: "SemanticMemory",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "SemanticMemoryTests",
            dependencies: ["SemanticMemory"]
        ),
    ]
)
