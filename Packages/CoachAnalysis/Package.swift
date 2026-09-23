// swift-tools-version: 5.9
import PackageDescription

// The Coach's free-form analysis: a declarative spec the model writes, validated and executed on device.
// Foundation only, on purpose: the package is the single source of the analysis semantics for the app AND
// for `Tools/CoachEval`, so it must build and test in seconds, anywhere, with no database underneath.
let package = Package(
    name: "CoachAnalysis",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "CoachAnalysis", targets: ["CoachAnalysis"]),
    ],
    targets: [
        // Optimised even in Debug for the same reason as StrandAnalytics: Xcode compiles package targets
        // from the configuration NAME, and the block bootstrap resamples thousands of times per question.
        .target(name: "CoachAnalysis", swiftSettings: [.unsafeFlags(["-O"])]),
        .testTarget(name: "CoachAnalysisTests", dependencies: ["CoachAnalysis"]),
    ]
)
