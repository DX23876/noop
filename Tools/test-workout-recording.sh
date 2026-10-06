#!/bin/bash
# Runs the actual pure timeline and its XCTest roster without an app build.
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_temp="$(mktemp -d /tmp/noop-recording-tests.XXXXXX)"
trap 'rm -rf "$task_temp"' EXIT
task_frameworks="$(xcode-select -p)/Platforms/MacOSX.platform/Developer/Library/Frameworks"
task_support="$task_frameworks/../../usr/lib"
task_tests="$task_root/Packages/StrandAnalytics/Tests/StrandAnalyticsTests/WorkoutRecordingTimelineTests.swift"
sed '/^@testable import StrandAnalytics$/d' "$task_tests" > "$task_temp/Tests.swift"
awk '
BEGIN {
    print "import XCTest\nimport Darwin\nlet expected: Set<String> = ["
    print "\"testCurrentZoneStreakUsesOneClockAndResetsOnDropoutOrZoneChange\","
    print "\"testPauseHistorySurvivesRestoreWithoutResumingAManualPause\","
    print "\"testRollingPaceRequiresFiveSecondsAndExpires\","
    print "\"testSplitCrossingIsInterpolatedAndTailIsPartial\","
    print "\"testManualPauseExcludesMissingLegAndResetsCurrentSpeed\","
    print "\"testMeasurementGapNeverGetsInterpolatedIntoASplit\","
    print "\"testTimeOnlyManualLapsAreIndependentOfDistance\","
    print "\"testZonesKeepOriginalBoundsAndDoNotCreditDropoutsOrBelowZoneOne\","
    print "\"testMileSplitsAndManualLapsDoNotResetEachOther\","
    print "\"testInvalidAndOutOfOrderEvidenceIsIgnored\","
    print "]\nlet suite = WorkoutRecordingTimelineTests.defaultTestSuite"
    print "let observed = Set(suite.tests.map { $0.name.split(separator: \" \" ).last!.dropLast().description })"
    print "guard observed == expected else { fatalError(\"Recording XCTest roster mismatch; update the explicit expected roster after reviewing new/renamed tests. This local runner does not exercise app adapters or physical GPS.\") }"
    print "suite.run()"
    print "guard let run = suite.testRun, run.executionCount == expected.count, run.totalFailureCount == 0 else { exit(1) }"
}
' "$task_tests" > "$task_temp/main.swift"
xcrun swiftc -F "$task_frameworks" -I "$task_support" -L "$task_support" \
    -Xlinker -rpath -Xlinker "$task_frameworks" -Xlinker -rpath -Xlinker "$task_support" \
    -module-cache-path "$task_temp/cache" \
    "$task_root/Packages/StrandAnalytics/Sources/StrandAnalytics/WorkoutRecordingTimeline.swift" \
    "$task_root/Packages/StrandAnalytics/Sources/StrandAnalytics/WorkoutGuidance.swift" \
    "$task_root/Packages/StrandAnalytics/Sources/StrandAnalytics/WorkoutPacer.swift" \
    "$task_temp/Tests.swift" "$task_temp/main.swift" -o "$task_temp/tests"
"$task_temp/tests"
