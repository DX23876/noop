// swift-tools-version:5.9
import PackageDescription

// The Android app's door into StrandCore (docs/fork/android/PLAN.md, phase D-5). `NoopCore` is a shared
// library the Android app loads with System.loadLibrary("NoopCore"); its JNI entry points convert Java
// arguments and call the plain Swift functions in Bridge.swift, which the tests here exercise on macOS.
// Built for Android by android/swift-core/build-swift-core.sh, which Gradle runs. `Sources/NoopCore/Shared` links app
// files whose logic Android needs unchanged (training, journal, caffeine; Android parity plan 1.2): one source,
// compiled into the Apple app and into this library, so both platforms run the same code.
let package = Package(
    name: "NoopCoreJNI",
    platforms: [.macOS(.v13)],
    products: [.library(name: "NoopCore", type: .dynamic, targets: ["NoopCore"])],
    dependencies: [
        .package(path: "../StrandCore"),
        .package(path: "../WhoopStore"),
        .package(path: "../WhoopProtocol"),
        .package(path: "../StrandAnalytics"),
        .package(path: "../StrandTraining"),
        .package(path: "../StrandImport"),
    ],
    targets: [
        // jni.h and the looper come from the NDK sysroot on Android; elsewhere the header is empty and unused.
        .target(name: "CJNI", linkerSettings: [.linkedLibrary("android", .when(platforms: [.android]))]),
        .target(
            name: "NoopCore",
            dependencies: [.product(name: "StrandCore", package: "StrandCore"),
                           .product(name: "WhoopStore", package: "WhoopStore"),
                           .product(name: "WhoopProtocol", package: "WhoopProtocol"),
                           .product(name: "StrandAnalytics", package: "StrandAnalytics"),
                           .product(name: "StrandTraining", package: "StrandTraining"),
                           .product(name: "StrandImport", package: "StrandImport"),
                           .target(name: "CJNI", condition: .when(platforms: [.android]))],
            // Set for the app sources the core compiles (`Sources/NoopCore/Shared`), where a few Apple-only
            // pieces are left out: the core has no resource bundle for `String(localized:bundle:)`.
            swiftSettings: [.define("NOOP_CORE")]),
        .testTarget(name: "NoopCoreTests", dependencies: [
            "NoopCore", .product(name: "WhoopStore", package: "WhoopStore"),
            .product(name: "StrandAnalytics", package: "StrandAnalytics"),
            .product(name: "StrandTraining", package: "StrandTraining"),
            .product(name: "WhoopProtocol", package: "WhoopProtocol")],
            resources: [.copy("Fixtures")], swiftSettings: [.define("NOOP_CORE_TESTS")]),
    ]
)
