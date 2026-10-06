#!/bin/bash
# Exercises the actual display resolver and fresh timeline, without an app build.
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_temp="$(mktemp -d /tmp/noop-speed-display-tests.XXXXXX)"
trap 'rm -rf "$task_temp"' EXIT
task_frameworks="$(xcode-select -p)/Platforms/MacOSX.platform/Developer/Library/Frameworks"
task_support="$task_frameworks/../../usr/lib"
sed '/^import StrandAnalytics$/d; /^@testable import Strand$/d' \
    "$task_root/StrandTests/WorkoutSpeedDisplayTests.swift" > "$task_temp/Tests.swift"
printf '%s\n' \
    'import XCTest' 'import Darwin' \
    'let expected: Set<String> = [' \
    '"testBeforeTheFirstMeasurementThereIsNoInventedValue",' \
    '"testDisplayHoldsSpeedWhenFreshMeasurementExpires",' \
    '"testPauseAndRecoveryWarmupKeepThePreviousNumber",' \
    '"testLongSignalGapHoldsUntilAnotherValidMeasurement",' \
    '"testInvalidMeasurementsCannotReplaceThePreviousNumber",' \
    '"testAReplacementWorkoutCannotInheritThePreviousReading",' \
    '"testEndingAndRestartingEvenTheSameIdentityClearsTheNumber",' \
    ']' \
    'let suite = WorkoutSpeedDisplayTests.defaultTestSuite' \
    'let observed = Set(suite.tests.map { $0.name.split(separator: " ").last!.dropLast().description })' \
    'guard observed == expected else { fatalError("Speed display XCTest roster mismatch. Review changes before updating the explicit roster. This runner does not exercise AppModel wiring, SwiftUI rendering or physical GPS.") }' \
    'suite.run()' \
    'guard let run = suite.testRun, run.executionCount == expected.count, run.totalFailureCount == 0 else { exit(1) }' \
    > "$task_temp/main.swift"
xcrun swiftc -F "$task_frameworks" -I "$task_support" -L "$task_support" \
    -Xlinker -rpath -Xlinker "$task_frameworks" -Xlinker -rpath -Xlinker "$task_support" \
    -module-cache-path "$task_temp/cache" \
    "$task_root/Strand/App/WorkoutSpeedDisplay.swift" \
    "$task_root/Packages/StrandAnalytics/Sources/StrandAnalytics/WorkoutRecordingTimeline.swift" \
    "$task_root/Packages/StrandAnalytics/Sources/StrandAnalytics/WorkoutGuidance.swift" \
    "$task_root/Packages/StrandAnalytics/Sources/StrandAnalytics/WorkoutPacer.swift" \
    "$task_temp/Tests.swift" "$task_temp/main.swift" -o "$task_temp/tests"
"$task_temp/tests"
