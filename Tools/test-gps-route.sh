#!/bin/bash
# Runs the production GPS math/filter/journal and their XCTest suite without building the app.
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_temp="$(mktemp -d /tmp/noop-gps-tests.XXXXXX)"
trap 'rm -rf "$task_temp"' EXIT
task_frameworks="$(xcode-select -p)/Platforms/MacOSX.platform/Developer/Library/Frameworks"
if [[ -n "${DEVELOPER_DIR:-}" ]]; then
    task_frameworks="$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/Library/Frameworks"
fi

# Only the platform wrapper is excluded; production math and storage are copied unchanged.
awk '/^enum RouteMath/ { emit=1 } /^\/\/ MARK: - GpsWorkoutRecorder/ { emit=0 } emit' \
    "$task_root/Strand/App/GpsWorkoutRecorder.swift" > "$task_temp/RouteMathAndStore.swift"
sed '1i\
import Foundation\
' "$task_temp/RouteMathAndStore.swift" > "$task_temp/RouteSupport.swift"
sed '/^@testable import Strand$/d' "$task_root/StrandTests/GpsRouteMathTests.swift" \
    > "$task_temp/GpsRouteMathTests.swift"

# Stable expected roster: deleting or renaming a regression cannot silently turn this gate green.
awk '
BEGIN {
    print "import XCTest\nimport Darwin\nlet expectedNames: Set<String> = ["
    print "\"testRouteJournalKeepsSegmentsAndActiveTime\","
    print "\"testRecordedDistanceNeverBridgesPauseOrRestore\","
    print "\"testSportSpeedCeilingCanAcceptACyclingLeg\","
    print "\"testHaversineKnownDistance\","
    print "\"testTotalDistanceSumsSegments\","
    print "\"testTotalDistanceEmptyOrSingleIsZero\","
    print "\"testDistanceAccumulatesAcrossGrowingTrack\","
    print "\"testPaceSecPerKm\","
    print "\"testActiveElapsedSecondsExcludesCompletedPauses\","
    print "\"testPolylineRoundTrips\","
    print "\"testEncodeEmptyIsEmptyString\","
    print "\"testPolylineMatchesGoogleReferenceGolden\","
    print "\"testDecodeTruncatedStopsCleanly\","
    print "\"testDecodeGarbageDoesNotCrash\","
    print "\"testFilterDropsLowAccuracyFixes\","
    print "\"testFilterDropsInvalidNegativeAccuracy\","
    print "\"testFilterDropsCachedFixFromBeforeCaptureWindow\","
    print "\"testFilterDropsTeleportJumps\","
    print "\"testFilterRejectsOutOfRangeCoordinates\","
    print "\"testFilterDoesNotTurnStationaryAccuracyJitterIntoDistance\","
    print "\"testIndoorCoarseFixesWithoutMotionEvidenceDoNotCreate150Meters\","
    print "\"testMinimalCoarsePositionJumpWithoutSpeedIsNotDistance\","
    print "\"testCoarsePositionIsRejectedEvenWithAConfidentSpeedEstimate\","
    print "\"testPositionJumpMustAgreeWithMeasuredSpeed\","
    print "\"testPhoneModeRejectsCoordinateDriftEvenAtReportedGoodAccuracy\","
    print "\"testPhoneModeStartsAtZeroThenRecordsReliableSlowWalking\","
    print "\"testPhoneModeAccurateZeroSpeedDoesNotAccumulateStationaryDrift\","
    print "\"testPhoneModeCountsWalkingWithImpreciseSpeedBeyondTheAccuracyCircles\","
    print "\"testGapIsBridgedWhenTheSportCeilingExplainsTheJump\","
    print "\"testGapReanchorsWhenTheJumpCannotBeExplained\","
    print "\"testLongGapBeyondTheBridgeLimitsReanchors\","
    print "\"testFilterEventuallyAcceptsRealSlowMovementBeyondUncertainty\","
    print "\"testSystemStationaryFlagRejectsEvenLargePositionDrift\","
    print "\"testAccurateZeroSpeedRejectsDriftBeforeSystemDeclaresStationary\","
    print "\"testReliableSlowWalkingPreservesShortLegsAtPoorPositionalAccuracy\","
    print "\"testReliableMotionPreservesSmallLoopInsteadOfCuttingCorners\","
    print "\"testMotionEvidenceNeverOverridesBadAccuracyOrTeleportGate\","
    print "\"testInvalidOrUncertainSpeedDoesNotBypassJitterFallback\","
    print "\"testDuplicateAndBackwardsTimesCannotBypassFiltering\","
    print "\"testRejectedStationaryUpdateStillOrdersSubsequentFixes\","
    print "\"testNonfiniteAccuracyIsInvalid\","
    print "\"testRouteStoreRoundTrip\","
    print "\"testRouteStorePreservesOriginalPointMeasurements\","
    print "\"testLegacyRouteWithoutPointMeasurementsRemainsReadableButCannotExport\","
    print "\"testSeamAfterRestoreIsJudgedBySpeedNotAssumed\","
    print "\"testFilterReturnsTheFixCoordinatesSoBankedPointsRebuildTheTrack\","
    print "\"testRouteMeasurementsRequireMonotonicValidTimesAndAccuracy\","
    print "\"testRouteStoreKeysBySportAndStart\","
    print "\"testRouteStoreRejectsEmptyPolyline\","
    print "\"testRouteStoreDropsNonFiniteDistanceOnDecode\","
    print "\"testRouteStoreEvictsOldestPastCap\","
    print "\"testRouteStoreReKeyOnNaturalKeyChangePreservesRoute\","
    print "\"testRouteStoreReKeyNoRouteIsNoOp\","
    print "\"testImportedRouteRoundTripsUnderWorkoutNaturalKey\","
    print "\"testStoreAllMatchesRepeatedSingleStores\","
    print "\"testStoreAllWithNoRoutesWritesNothing\","
    print "\"testImportedWorkoutWithoutRouteLoadsNil\","
    print "]\nlet suite = GpsRouteMathTests.defaultTestSuite"
    print "let observedNames = Set(suite.tests.map { $0.name.split(separator: \" \" ).last!.dropLast().description })"
    print "guard observedNames == expectedNames else { fatalError(\"GPS XCTest roster mismatch: review renamed/added/deleted tests and update the explicit expected roster. This runner does not exercise the recorder adapter, native GPS hardware or UI.\") }"
    print "suite.run()"
    print "guard let run = suite.testRun, run.executionCount == expectedNames.count, run.totalFailureCount == 0 else { exit(1) }"
}
' "$task_root/StrandTests/GpsRouteMathTests.swift" > "$task_temp/main.swift"

task_swift_support="$task_frameworks/../../usr/lib"
xcrun swiftc -F "$task_frameworks" -I "$task_swift_support" -L "$task_swift_support" \
    -Xlinker -rpath -Xlinker "$task_frameworks" \
    -Xlinker -rpath -Xlinker "$task_swift_support" \
    -module-cache-path "$task_temp/module-cache" \
    "$task_temp/RouteSupport.swift" "$task_root/Strand/App/RawFix.swift" \
    "$task_root/Strand/App/TrackFilter.swift" "$task_root/Strand/App/ActiveRouteJournal.swift" \
    "$task_temp/GpsRouteMathTests.swift" "$task_temp/main.swift" -o "$task_temp/gps-tests"
"$task_temp/gps-tests"
