import XCTest
@testable import StrandTraining

final class ExerciseCatalogSeedTests: XCTestCase {

    private func decide(seeded: Int, starter: Int = 2, stored: Int?, shipped: Int = 1_300,
                        content: Int = 3, starterVersion: Int = 2)
        -> ExerciseCatalogSeed.Decision {
        ExerciseCatalogSeed.decide(seededContentVersion: seeded, seededStarterVersion: starter,
                                   storedCount: stored, shippedCount: shipped,
                                   contentVersion: content, starterVersion: starterVersion)
    }

    func testANewContentVersionSeedsEverything() {
        XCTAssertEqual(decide(seeded: 2, stored: 1_300), .full(.newContentVersion))
        XCTAssertEqual(decide(seeded: 0, stored: 0), .full(.newContentVersion))
    }

    func testACurrentCompleteCatalogueIsLeftAlone() {
        XCTAssertEqual(decide(seeded: 3, stored: 1_300), .none)
        // A wearer's own exercises push the count ABOVE the shipped floor. That is not a reason to
        // re-seed, and treating "not exactly equal" as damage would re-write 1,300 rows on every
        // launch for anyone who ever created an exercise.
        XCTAssertEqual(decide(seeded: 3, stored: 1_412), .none)
    }

    func testAFlagThatOUTRUNSTheStoreForcesAReseed() {
        // The reported bug: the flag was written although the write had thrown, so the app believed
        // in a catalogue that was not there. This is the case that repairs an install already stuck.
        XCTAssertEqual(decide(seeded: 3, stored: 0),
                       .full(.incomplete(stored: 0, expected: 1_300)))
        XCTAssertEqual(decide(seeded: 3, stored: 42),
                       .full(.incomplete(stored: 42, expected: 1_300)))
    }

    func testAnUnreadableCountIsTreatedAsIntact() {
        // Never re-seed on the strength of a read that failed: that turns one transient fault into
        // 1,300 writes on every launch. The next launch settles it.
        XCTAssertEqual(decide(seeded: 3, stored: nil), .none)
        // …unless something else already asked for a seed.
        XCTAssertEqual(decide(seeded: 2, stored: nil), .full(.newContentVersion))
    }

    func testTheStarterCatalogueCanMoveOnItsOwn() {
        XCTAssertEqual(decide(seeded: 3, starter: 1, stored: 1_300), .starterOnly)
        // A full seed writes the starter definitions too, so it wins — asking for both would write
        // the starter rows twice.
        XCTAssertEqual(decide(seeded: 2, starter: 1, stored: 1_300), .full(.newContentVersion))
        XCTAssertEqual(decide(seeded: 3, starter: 1, stored: 0),
                       .full(.incomplete(stored: 0, expected: 1_300)))
    }

    func testTheShippedCatalogueIsActuallyShipped() {
        // The decision above is only worth anything if `shippedCount` is a real number. An empty
        // bundled catalogue — a resource that did not make it into the app — would make every
        // install look complete at zero definitions.
        XCTAssertGreaterThan(BundledExerciseCatalog.exercises.count, 500,
                             "the bundled catalogue resource is missing or empty")
        XCTAssertFalse(TrainingStarterCatalog.exercises.isEmpty)
    }
}
