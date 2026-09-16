import XCTest
@testable import StrandTraining

final class BundledExerciseCatalogTests: XCTestCase {
    func testTheShippedCatalogueLoadsAndPassesItsOwnValidation() {
        XCTAssertEqual(BundledExerciseCatalog.validationIssues(), [])
        XCTAssertGreaterThanOrEqual(BundledExerciseCatalog.exercises.count, 1_300)
        XCTAssertEqual(Set(BundledExerciseCatalog.exercises.map(\.id)).count,
                       BundledExerciseCatalog.exercises.count)
    }

    func testProvenanceAndLicenceTravelWithTheContent() throws {
        let archive = BundledExerciseCatalog.archive
        XCTAssertEqual(archive.provider, "exercisedb-v1")
        XCTAssertEqual(archive.rights.licence, "MIT")
        XCTAssertTrue(archive.rights.allowsOfflineCache)
        let revision = try XCTUnwrap(archive.sourceRevision)
        XCTAssertTrue(revision.hasPrefix("hasaneyldrm/exercises-dataset@"), revision)
        XCTAssertEqual(try XCTUnwrap(archive.sourceChecksum).count, 64)
        let attribution = try XCTUnwrap(archive.rights.attribution)
        XCTAssertTrue(attribution.contains("MIT"))

        for exercise in BundledExerciseCatalog.exercises.prefix(100) {
            XCTAssertEqual(exercise.source, .exerciseDB)
            XCTAssertEqual(exercise.contentVersion, BundledExerciseCatalog.contentVersion)
            XCTAssertEqual(exercise.canonicalId, exercise.id)
            XCTAssertNotNil(exercise.sourceId)
            XCTAssertFalse(exercise.attribution?.isEmpty ?? true)
        }
    }

    /// The upstream's MIT licence covers the data; the images and animations belong to Gym visual and
    /// are expressly not licensed by cloning. Nothing but an opaque identifier may ship here — no file
    /// name, no path, no URL — and the provider that could resolve one is withdrawn.
    func testNoMediaTravelsWithTheCatalogue() {
        for exercise in BundledExerciseCatalog.exercises {
            guard let mediaId = exercise.mediaId else { continue }
            XCTAssertFalse(mediaId.contains("/"), exercise.id)
            XCTAssertFalse(mediaId.contains("."), exercise.id)
            XCTAssertFalse(mediaId.lowercased().contains("http"), exercise.id)
        }
    }

    func testKnownLiftsAreNormalizedIntoNoopsOwnDomain() throws {
        let byTitle = Dictionary(BundledExerciseCatalog.exercises.map { ($0.title, $0) },
                                 uniquingKeysWith: { first, _ in first })

        let bench = try XCTUnwrap(byTitle["Barbell Bench Press"])
        XCTAssertEqual(bench.mode, .weightReps)
        XCTAssertEqual(bench.primaryMuscleId, "chest")
        XCTAssertEqual(bench.equipmentIds, ["barbell"])
        XCTAssertEqual(bench.effectiveLoadSemantics, .totalExternalLoad)
        XCTAssertFalse(bench.instructions.isEmpty)

        let pullUp = try XCTUnwrap(byTitle["Pull-Up"])
        XCTAssertEqual(pullUp.mode, .bodyweightReps)
        XCTAssertEqual(pullUp.primaryMuscleId, "lats")

        // A prop supports the body without loading it, so the body stays the load.
        let ballCrunch = try XCTUnwrap(byTitle["Crunch (On Stability Ball)"])
        XCTAssertEqual(ballCrunch.mode, .bodyweightReps)
        XCTAssertTrue(ballCrunch.equipmentIds.contains("stability-ball"))
        XCTAssertFalse(TrainingEquipmentCatalog.carriesExternalLoad(ballCrunch.equipmentIds))

        // Upstream files rotational core work under "abs"; the obliques are its main target.
        let twist = try XCTUnwrap(byTitle["Russian Twist"])
        XCTAssertEqual(twist.primaryMuscleId, "obliques")
        XCTAssertEqual(twist.secondaryMuscleIds, ["abdominals"])
        XCTAssertEqual(try XCTUnwrap(byTitle["Crunch (On Stability Ball)"]).primaryMuscleId, "abdominals")
    }

    /// Every entry with a muscle has to reach the muscle map, or the catalogue would grow the library
    /// without growing what the analytics can attribute.
    func testCatalogueEntriesResolveToAnatomyForTheMuscleMap() {
        let mapped = BundledExerciseCatalog.exercises.filter { $0.primaryMuscleId != nil }
        XCTAssertGreaterThan(mapped.count, 1_200)
        for exercise in mapped.prefix(300) {
            XCTAssertNotNil(TrainingMuscleProjection.anatomy(for: exercise), exercise.id)
        }
    }

    /// Conditioning work trains no single muscle, so it claims no PRIMARY one. It may still name the
    /// muscles it involves — a burpee does use the quadriceps — but without a primary muscle it resolves
    /// to no anatomy, and therefore colours nothing on the muscle map. That is the honest split: keep
    /// the information, refuse the attribution.
    func testConditioningEntriesClaimNoPrimaryMuscleAndColourNoMap() {
        let cardio = BundledExerciseCatalog.exercises.filter { $0.primaryMuscleId == nil }
        XCTAssertFalse(cardio.isEmpty)
        for exercise in cardio {
            XCTAssertEqual(exercise.mode, .duration, exercise.id)
            XCTAssertNil(TrainingMuscleProjection.anatomy(for: exercise), exercise.id)
        }
    }
}

/// Starter exercises borrow media only from bundled entries that exist, and only for starter ids.
final class StarterMediaReferenceTests: XCTestCase {
    func testEveryStarterMediaReferencePointsAtABundledEntry() {
        let bundledMedia = Set(BundledExerciseCatalog.exercises.compactMap(\.mediaId))
        let starterIds = Set(TrainingStarterCatalog.exercises.map { String($0.id.dropFirst("noop:".count)) })
        for (starter, media) in TrainingStarterCatalog.mediaReferences {
            XCTAssertTrue(starterIds.contains(starter), starter)
            XCTAssertTrue(bundledMedia.contains(media), "\(starter) -> \(media)")
        }
        XCTAssertNil(TrainingStarterCatalog.exercises.first { $0.id == "noop:plank" }?.mediaId)
        XCTAssertEqual(TrainingStarterCatalog.exercises.first { $0.id == "noop:barbell-bench-press" }?.mediaId,
                       "EIeI8Vf")
    }
}
