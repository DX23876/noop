#!/bin/bash
# Exercises the actual CLLocation-to-recorder adapter and shared filter without an app build.
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_temp="$(mktemp -d /tmp/noop-gps-recorder-tests.XXXXXX)"
trap 'rm -rf "$task_temp"' EXIT
task_frameworks="$(xcode-select -p)/Platforms/MacOSX.platform/Developer/Library/Frameworks"
task_support="$task_frameworks/../../usr/lib"

# Production declarations are unchanged; flatten only imports and the unrelated trace types.
sed '/^import StrandAnalytics/d' "$task_root/Strand/App/GpsWorkoutRecorder.swift" > "$task_temp/Recorder.swift"
sed '/^import StrandAnalytics/d' "$task_root/Strand/System/TestCentre.swift" > "$task_temp/TestCentre.swift"
sed '/^import StrandAnalytics/d; /^@testable import Strand$/d' \
    "$task_root/StrandTests/WorkoutsTestModeEmissionTests.swift" > "$task_temp/Tests.swift"
awk '/^public enum WorkoutsTrace/ { emit=1 } /^public enum WorkoutsReadout/ { emit=0 } emit' \
    "$task_root/Packages/StrandAnalytics/Sources/StrandAnalytics/AutoWorkoutDetector+Trace.swift" > "$task_temp/Trace.swift"
awk '
BEGIN {
    print "import XCTest\nimport Darwin\nMainActor.assumeIsolated {"
    print "let expected: Set<String> = ["
    print "\"testModeOffEmitsZeroWorkoutsLines\","
    print "\"testModeOnEmitsAGpsFixLine\","
    print "\"testCachedFixFromBeforeWorkoutDoesNotCreateStationaryDistance\","
    print "\"testIndoorDriftDoesNotReachDisplayedOrRecordedDistance\","
    print "\"testUnavailableOrApproximateLocationsCannotStartARoute\","
    print "\"testSignalLossFreezesDistanceAndAnUnexplainedRecoveryOnlySetsANewAnchor\","
    print "\"testAnOutageTheMovementExplainsIsBridged\","
    print "\"testAnUnavailableDeliveryWithCoordinatesCannotBridgeRecovery\","
    print "\"testOneUntrustedFixIsSkippedButARunOfThemIsAnOutage\","
    print "]\nlet suite = WorkoutsTestModeEmissionTests.defaultTestSuite"
    print "let observed = Set(suite.tests.map { $0.name.split(separator: \" \" ).last!.dropLast().description })"
    print "guard observed == expected else { fatalError(\"GPS adapter XCTest roster mismatch. Review changed tests and update the explicit expected roster. This runner does not exercise physical GPS, the native CLLocationUpdate stream or SwiftUI rendering.\") }"
    print "suite.run()"
    print "guard let run = suite.testRun, run.executionCount == expected.count, run.totalFailureCount == 0 else { exit(1) }\n}"
}
' > "$task_temp/main.swift"
xcrun swiftc -F "$task_frameworks" -I "$task_support" -L "$task_support" \
    -Xlinker -rpath -Xlinker "$task_frameworks" -Xlinker -rpath -Xlinker "$task_support" \
    -module-cache-path "$task_temp/cache" \
    "$task_temp/Recorder.swift" "$task_temp/TestCentre.swift" "$task_temp/Tests.swift" "$task_temp/Trace.swift" \
    "$task_root/Packages/StrandAnalytics/Sources/StrandAnalytics/TestDomain.swift" \
    "$task_root/Strand/App/RawFix.swift" "$task_root/Strand/App/TrackFilter.swift" \
    "$task_root/Strand/App/ActiveRouteJournal.swift" "$task_root/Strand/App/WorkoutGPSState.swift" \
    "$task_temp/main.swift" -o "$task_temp/tests"
"$task_temp/tests"
