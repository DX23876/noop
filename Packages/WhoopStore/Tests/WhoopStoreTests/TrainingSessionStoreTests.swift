import XCTest
@testable import WhoopStore

final class TrainingSessionStoreTests: XCTestCase {
    func testMetadataHeartRateLinksAndPreferencesRoundTrip() async throws {
        let store = try await WhoopStore.inMemory()
        let metadata = WorkoutSourceMetadataRow(componentKey: "apple|1", source: "apple-health",
            startTs: 1_000, sport: "Running", externalId: "uuid", sourceBundleId: "com.example",
            rawActivityType: 37, activitiesJSON: "[]", updatedAtTs: 2_000)
        try await store.upsertWorkoutSourceMetadata([metadata])
        let readMetadata = try await store.workoutSourceMetadata(from: 900, to: 1_100)
        XCTAssertEqual(readMetadata, [metadata])

        let buckets = [WorkoutHeartRateBucketRow(componentKey: "apple|1", bucketStart: 1_020,
                                                  bpm: 151, sourceBundleId: "com.example")]
        try await store.replaceWorkoutHeartRateBuckets(componentKey: "apple|1", rows: buckets)
        let readBuckets = try await store.workoutHeartRateBuckets(componentKey: "apple|1")
        XCTAssertEqual(readBuckets, buckets)

        let link = TrainingSessionLinkRow(componentKey: "apple|1", sessionId: "session|1",
                                          origin: "automatic", updatedAtTs: 2_000)
        try await store.upsertTrainingSessionLinks([link])
        let readLinks = try await store.trainingSessionLinks()
        XCTAssertEqual(readLinks, [link])

        let decision = TrainingSessionPairDecisionRow(leftKey: "hevy|1", rightKey: "apple|1",
                                                       decision: "separate", updatedAtTs: 2_001)
        try await store.upsertTrainingSessionPairDecision(decision)
        let readDecisions = try await store.trainingSessionPairDecisions()
        XCTAssertEqual(readDecisions, [decision])

        let preference = TrainingSessionPreferenceRow(sessionId: "session|1", activityKind: "conditioning",
                                                       primaryComponentKey: "apple|1", updatedAtTs: 2_002)
        try await store.upsertTrainingSessionPreference(preference)
        let readPreferences = try await store.trainingSessionPreferences()
        XCTAssertEqual(readPreferences, [preference])
    }

    func testDeletingLinksIsScopedToTheNamedComponents() async throws {
        let store = try await WhoopStore.inMemory()
        let links = ["native-training|1|strength", "manual|1|strength", "apple|2"].map {
            TrainingSessionLinkRow(componentKey: $0, sessionId: "session|1", origin: "native-lifecycle",
                                   updatedAtTs: 2_000)
        }
        try await store.upsertTrainingSessionLinks(links)
        let removed = try await store.deleteTrainingSessionLinks(componentKeys: ["native-training|1|strength",
                                                                                 "missing"])
        XCTAssertEqual(removed, 1)
        let remaining = try await store.trainingSessionLinks().map(\.componentKey).sorted()
        XCTAssertEqual(remaining, ["apple|2", "manual|1|strength"])
        let none = try await store.deleteTrainingSessionLinks(componentKeys: [])
        XCTAssertEqual(none, 0)
    }

    func testReplacingHeartRateBucketsIsScopedToOneComponent() async throws {
        let store = try await WhoopStore.inMemory()
        let metadata = ["a", "b"].map { key in
            WorkoutSourceMetadataRow(componentKey: key, source: "apple-health", startTs: 1,
                sport: "Running", externalId: nil, sourceBundleId: nil, rawActivityType: nil,
                activitiesJSON: nil, updatedAtTs: 1)
        }
        try await store.upsertWorkoutSourceMetadata(metadata)
        try await store.replaceWorkoutHeartRateBuckets(componentKey: "a", rows: [
            .init(componentKey: "a", bucketStart: 10, bpm: 140, sourceBundleId: nil)])
        try await store.replaceWorkoutHeartRateBuckets(componentKey: "b", rows: [
            .init(componentKey: "b", bucketStart: 10, bpm: 150, sourceBundleId: nil)])
        try await store.replaceWorkoutHeartRateBuckets(componentKey: "a", rows: [])
        let remainingA = try await store.workoutHeartRateBuckets(componentKey: "a")
        let remainingB = try await store.workoutHeartRateBuckets(componentKey: "b")
        XCTAssertTrue(remainingA.isEmpty)
        XCTAssertEqual(remainingB.map(\.bpm), [150])
    }
}
