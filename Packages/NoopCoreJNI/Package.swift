// swift-tools-version:5.9
import PackageDescription

// The Android app's door into StrandCore (docs/fork/android/PLAN.md, phase D-5). `NoopCore` is a shared
// library the Android app loads with System.loadLibrary("NoopCore"); its JNI entry points convert Java
// arguments and call the plain Swift functions in Bridge.swift, which the tests here exercise on macOS.
// Built for Android by android/swift-core/build-swift-core.sh, which Gradle runs.
let package = Package(
    name: "NoopCoreJNI",
    platforms: [.macOS(.v13)],
    products: [.library(name: "NoopCore", type: .dynamic, targets: ["NoopCore"])],
    dependencies: [
        .package(path: "../StrandCore"),
        .package(path: "../WhoopStore"),
    ],
    targets: [
        // jni.h comes from the NDK sysroot on Android; elsewhere the header is empty and nothing uses it.
        .target(name: "CJNI"),
        .target(
            name: "NoopCore",
            dependencies: [.product(name: "StrandCore", package: "StrandCore"),
                           .product(name: "WhoopStore", package: "WhoopStore"),
                           .target(name: "CJNI", condition: .when(platforms: [.android]))]),
        .testTarget(name: "NoopCoreTests", dependencies: ["NoopCore"]),
    ]
)
