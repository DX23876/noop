import XCTest
@testable import StrandAnalytics

final class SessionRatingPolicyTests: XCTestCase {

    private func family(_ sport: String) -> SessionRatingPolicy.Family {
        SessionRatingPolicy.family(forSport: sport)
    }

    func testCatalogSportsLandInTheirFamily() {
        let expected: [SessionRatingPolicy.Family: [String]] = [
            .resistance: ["Strength", "Bodybuilding", "Weightlifting", "Powerlifting", "HIIT", "Pilates",
                          "Climbing", "Gymnastics", "Calisthenics", "Boot camp", "CrossFit"],
            .intermittent: ["Soccer", "Basketball", "Handball", "Rugby", "Ice Hockey", "Field hockey",
                            "Water polo", "Tennis", "Table tennis", "Padel", "Sand volleyball",
                            "American football", "Hurling/Camogie", "Polo"],
            .combat: ["Boxing", "Kickboxing", "Martial arts", "Judo", "Jiu jitsu", "Muay Thai", "Fencing"],
            .swimming: ["Pool swim", "Open-water swim"],
            .steadyEndurance: ["Running", "Walking", "Hiking", "Rucking", "Nordic walking", "Cycling",
                               "Mountain biking", "Spinning", "Stair climber", "Stand-up paddleboard",
                               "Skiing", "Snowboarding", "Dancing", "Parkour", "Jump rope"],
            .lowLoad: ["Yoga", "Stretching", "Meditation", "Golf", "Disc golf", "Bowling", "Sailing",
                       "Scuba diving", "Skydiving", "Motocross", "Horseback riding", "Gaming"],
            .unknown: ["Other", "Workout", "detected", ""],
        ]
        for (family, sports) in expected {
            for sport in sports { XCTAssertEqual(self.family(sport), family, sport) }
        }
    }

    /// Imports arrive with their own spellings; each must find the family its catalog twin has.
    func testImportSpellingsResolve() {
        XCTAssertEqual(family("HKWorkoutActivityTypeTraditionalStrengthTraining"), .resistance)
        XCTAssertEqual(family("strength_training"), .resistance)
        XCTAssertEqual(family("Krafttraining"), .resistance)
        XCTAssertEqual(family("HKWorkoutActivityTypeCrossCountrySkiing"), .steadyEndurance)
        XCTAssertEqual(family("Wandern"), .steadyEndurance)
        XCTAssertEqual(family("HKWorkoutActivityTypeMindAndBody"), .lowLoad)
        XCTAssertEqual(family("HKWorkoutActivityTypeWaterPolo"), .intermittent)
    }

    /// Lifting, stop-and-go, combat, swimming and the unplaceable are always worth a rating — even a
    /// short, easy-looking session, because heart rate is what fails to describe them.
    func testSportsHeartRateCannotSpeakForAreAlwaysAsked() {
        for sport in ["Strength Training", "Tennis", "Boxing", "Pool swim", "Other"] {
            XCTAssertTrue(SessionRatingPolicy.isWorthRating(sport: sport, durationSeconds: 600,
                                                            averageHR: 80, restingHR: 60, maxHR: 190),
                          sport)
        }
    }

    /// The case that prompted the change: a walk to the bakery is not asked about; a long mountain
    /// hike and a hard short run are.
    func testSteadySessionsAreAskedWhenTheyWereSubstantial() {
        func ask(_ sport: String, minutes: Double, hr: Double?) -> Bool {
            SessionRatingPolicy.isWorthRating(sport: sport, durationSeconds: minutes * 60,
                                              averageHR: hr, restingHR: 60, maxHR: 190)
        }
        XCTAssertFalse(ask("Walking", minutes: 20, hr: 95))
        XCTAssertTrue(ask("Hiking", minutes: 180, hr: 110), "long: duration alone qualifies")
        XCTAssertTrue(ask("Hiking", minutes: 44, hr: 130), "50 % of the reserve is 125 bpm here")
        XCTAssertFalse(ask("Hiking", minutes: 44, hr: 120))
        XCTAssertTrue(ask("Running", minutes: 30, hr: 150))
        XCTAssertTrue(ask("Walking", minutes: 20, hr: nil), "no heart rate: nothing else describes it")
        XCTAssertFalse(ask("Yoga", minutes: 30, hr: 85))
        XCTAssertTrue(ask("Yoga", minutes: 75, hr: 85))
    }
}
