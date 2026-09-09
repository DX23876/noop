// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "StrandAnalytics",
    platforms: [.macOS(.v13), .iOS(.v16), .watchOS(.v10)],
    products: [.library(name: "StrandAnalytics", targets: ["StrandAnalytics"])],
    dependencies: [
        .package(path: "../WhoopProtocol"),
        .package(path: "../WhoopStore"),
    ],
    targets: [
        // OPTIMISED EVEN IN DEBUG, and this is load-bearing rather than tidy.
        //
        // `project.yml` sets `SWIFT_OPTIMIZATION_LEVEL: -O` on the Debug CONFIGURATION and its comment
        // says that reaches the local packages. It does not: Xcode compiles SPM package targets from
        // the configuration's NAME, not from the project's build settings, so Debug always meant
        // `-Onone` here. Verified by reading the flag off the actual compile —
        // `-module-name StrandAnalytics` was built `-Onone` in a Debug app build.
        //
        // The cost of that is not academic. One scored day is ~950 k samples through the sleep stager,
        // the HRV passes and the recovery scoring: at `-Onone` — no inlining, no generic specialisation,
        // retain/release on array access — it measured 2.37 s against 0.053 s optimised on the same
        // machine, a factor of 45. On a phone that is the difference between a 21-day pass costing
        // half a minute and costing twenty, and this app is debug-built in daily use rather than
        // occasionally.
        //
        // `unsafeFlags` is allowed because these packages are consumed by path, never as a versioned
        // dependency. Optimisation changes codegen, not `-g`, so symbols and breakpoints in the app
        // are unaffected — and the app target keeps its own `-Onone` so app code stays steppable.
        .target(name: "StrandAnalytics", dependencies: ["WhoopProtocol", "WhoopStore"],
                swiftSettings: [.unsafeFlags(["-O"])]),
        // WhoopStore is declared on the TEST target as well as the library: the Oura respiration
        // scoring-exclusion tests assert on `OuraRespScale` (the seam that keeps the ring's 0x6A rows
        // out of the stager), and a transitively-visible module is not something a test should rely on.
        // `Oracles/` holds the committed local-day-windows oracle the tests re-derive. Declared so SPM
        // does not warn about an unhandled file; the test reads it by path from `#filePath`, not from
        // the bundle, so it stays readable the same way in Xcode and on the command line. NOT `Fixtures/`
        // — the repo's .gitignore excludes that directory name everywhere (it is where real Health
        // exports land), so an oracle committed under it would silently never be committed at all.
        .testTarget(name: "StrandAnalyticsTests", dependencies: ["StrandAnalytics", "WhoopStore"],
                    resources: [.copy("Oracles")]),
    ]
)
