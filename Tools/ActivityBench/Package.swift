// swift-tools-version:5.9
import PackageDescription

// ActivityBench — the offline yardstick for activity detection (plan building block 3).
//
// Replays the shipped detectors over real days held in a NOOP SQLite database and scores their
// suggestions against the wearer's own entries with `ActivityDetectionScore`: one-to-one matches at an
// overlap of at least 0.3, hits per kind, suggestions without an entry per worn awake day, start and end
// error, with week-bootstrap intervals. The rules each detector uses are the shipped ones, read from
// `StrandAnalytics`, so the bench can never measure a copy that drifted from the app.
//
// The database path is ALWAYS a command-line argument — no health data lives in this repository, and
// none is ever written back. The tool is read-only (`SQLITE_OPEN_READONLY` + `immutable=1`).
let package = Package(
    name: "activitybench",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "../../Packages/StrandAnalytics"),
    ],
    targets: [
        .executableTarget(name: "activitybench", dependencies: ["StrandAnalytics"]),
        // The interval and the label read are pure over in-memory rows, so `swift test` needs no data.
        .testTarget(name: "activitybenchTests", dependencies: ["activitybench"]),
    ]
)
