// swift-tools-version:5.9
import PackageDescription

// CoachEval — the measuring instrument for the Coach's free-form analysis (docs/fork/COACH_ANALYSIS_PLAN.md).
//
// It asks a model questions about a SYNTHETIC wearer whose effects were injected at known sizes, lets the
// model answer through the real `run_analysis` tool from `Packages/CoachAnalysis`, and scores the answer
// against a reference computed independently of that tool. The pre-registered quality bar is judged on
// its output.
//
// `coach-eval oracle` runs every question's reference spec through the executor and scores it — no
// network, no key, and it is what the tests pin. `coach-eval run` calls a provider with the wearer's own
// API key and costs money; nothing runs it automatically. No NOOP database is opened and no wearer data
// is involved.
let package = Package(
    name: "CoachEval",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "../../Packages/CoachAnalysis"),
    ],
    targets: [
        .target(name: "CoachEvalCore", dependencies: ["CoachAnalysis"]),
        .executableTarget(name: "coach-eval", dependencies: ["CoachEvalCore", "CoachAnalysis"]),
        .testTarget(name: "CoachEvalCoreTests", dependencies: ["CoachEvalCore", "CoachAnalysis"]),
    ]
)
