import XCTest
@testable import StrandAnalytics

/// The population gate (owner decision 2026-11-27, Q12): invented days for six kinds of people, priced by
/// the strap model and the day engine, must land in the range doubly-labelled-water studies find for that
/// way of living, as a multiple of basal. A person outside the range blocks a release.
///
/// The ranges are the FAO/WHO/UNU bands (sedentary or light 1.40 to 1.69, active 1.70 to 1.99), digestion
/// included as those measurements include it (`Digestion`, the standard tenth: nobody here logs food), placed
/// within the band by how much each person moves: a day of 3,000 steps at its lower edge, 8,000 steps around
/// its middle, ten hours of training a week in the active band, a day in bed below it.
final class EnergyPersonaTests: XCTestCase {
    struct Persona {
        let name: String
        let profile: UserProfile
        let sleepHours: Double
        /// Minutes of ordinary walking at 100 steps a minute.
        let walkingMinutes: Int
        /// Minutes of a heart-rate workout and its heart rate, on the days that have one.
        let workoutMinutes: Int
        let workoutHR: Double
        let workoutKind: EnergyWorkoutKind
        let workoutOnFoot: Bool
        let workoutDaysPerWeek: Int
        let restingHR: Double
        let range: ClosedRange<Double>
    }

    private static let day0 = 1_795_219_200   // 2026-11-21 00:00 UTC

    /// One invented day: sleep from midnight, then walking spread through the waking hours, the workout
    /// in the evening, and everything else awake and still.
    static func day(_ persona: Persona, workout: Bool) -> [WhoopEnergyBucket] {
        let slots = 288
        let sleepSlots = Int(persona.sleepHours * 12)
        let walkSlots = persona.walkingMinutes / 5
        let workoutSlots = workout ? persona.workoutMinutes / 5 : 0
        let awake = Array(sleepSlots..<slots)
        let workoutStart = max(sleepSlots, slots - 36 - workoutSlots)
        let workoutRange = workoutStart..<(workoutStart + workoutSlots)
        let walkable = awake.filter { !workoutRange.contains($0) }
        let step = max(1, walkable.count / max(1, walkSlots))
        let walking = Set(stride(from: 0, to: walkable.count, by: step).prefix(walkSlots).map { walkable[$0] })
        return (0..<slots).map { slot in
            let start = day0 + slot * 300
            if slot < sleepSlots {
                return WhoopEnergyBucket(start: start, averageHR: persona.restingHR, isSleep: true)
            }
            if workoutRange.contains(slot) {
                return WhoopEnergyBucket(start: start, averageHR: persona.workoutHR,
                                         steps: persona.workoutOnFoot ? 800 : nil, isWorkout: true,
                                         workoutKind: persona.workoutKind, workoutOnFoot: persona.workoutOnFoot,
                                         hasMovementCoverage: true,
                                         movementSeconds: persona.workoutOnFoot ? 300 : 0)
            }
            if walking.contains(slot) {
                return WhoopEnergyBucket(start: start, averageHR: persona.restingHR + 30, steps: 500,
                                         activityClass: 1, hasMovementCoverage: true, movementSeconds: 300)
            }
            return WhoopEnergyBucket(start: start, averageHR: persona.restingHR + 12,
                                     activityClass: 0, hasMovementCoverage: true, movementSeconds: 0)
        }
    }

    /// The persona's week, as a multiple of basal: training days and rest days in their share.
    static func multiple(_ persona: Persona, peakMET: Double) throws -> Double {
        let bmr = try XCTUnwrap(Calories.bmrKcalPerDay(profile: persona.profile))
        func total(workout: Bool) throws -> Double {
            let estimate = try XCTUnwrap(WhoopEnergyModel.estimate(
                buckets: day(persona, workout: workout), profile: persona.profile,
                restingHR: persona.restingHR, maxHR: 220 - Double(persona.profile.age), peakMET: peakMET))
            let active = estimate.buckets.reduce(0) { $0 + $1.activeKcal }
            let inputs = EnergyEngine.DayInputs(
                day: "2026-11-21", strapTotalKcal: estimate.totalKcal,
                strapCoverageSeconds: estimate.representedSeconds, strapActiveKcal: active,
                strapEverydayKcal: estimate.everydayKcal)
            let summary = EnergyEngine.summarize(inputs, profile: persona.profile, context: .completePastDay)
            return try XCTUnwrap(summary.totalBurnedSoFar)
        }
        let training = Double(persona.workoutDaysPerWeek)
        let week = try total(workout: true) * training + total(workout: false) * (7 - training)
        return week / 7 / bmr
    }

    static let personas: [Persona] = [
        Persona(name: "thin, office, 3000 steps",
                profile: UserProfile(weightKg: 60, heightCm: 175, age: 30, sex: "male"),
                sleepHours: 8, walkingMinutes: 30, workoutMinutes: 0, workoutHR: 0, workoutKind: .other,
                workoutOnFoot: false, workoutDaysPerWeek: 0, restingHR: 62, range: 1.40...1.60),
        Persona(name: "normal weight, 8000 steps",
                profile: UserProfile(weightKg: 75, heightCm: 178, age: 40, sex: "male"),
                sleepHours: 7.5, walkingMinutes: 80, workoutMinutes: 0, workoutHR: 0, workoutKind: .other,
                workoutOnFoot: false, workoutDaysPerWeek: 0, restingHR: 60, range: 1.50...1.78),
        Persona(name: "very heavy, 8000 steps, strength three times a week",
                profile: UserProfile(weightKg: 200, heightCm: 196, age: 35, sex: "male"),
                sleepHours: 7.5, walkingMinutes: 80, workoutMinutes: 60, workoutHR: 125, workoutKind: .resistance,
                workoutOnFoot: false, workoutDaysPerWeek: 3, restingHR: 68, range: 1.50...1.78),
        Persona(name: "endurance athlete, ten hours a week",
                profile: UserProfile(weightKg: 70, heightCm: 180, age: 30, sex: "male"),
                sleepHours: 8, walkingMinutes: 60, workoutMinutes: 85, workoutHR: 150, workoutKind: .endurance,
                workoutOnFoot: true, workoutDaysPerWeek: 7, restingHR: 50, range: 1.75...2.10),
        Persona(name: "older woman, little movement",
                profile: UserProfile(weightKg: 65, heightCm: 162, age: 70, sex: "female"),
                sleepHours: 8, walkingMinutes: 40, workoutMinutes: 0, workoutHR: 0, workoutKind: .other,
                workoutOnFoot: false, workoutDaysPerWeek: 0, restingHR: 66, range: 1.40...1.60),
        Persona(name: "sick day, almost only in bed",
                profile: UserProfile(weightKg: 80, heightCm: 180, age: 35, sex: "male"),
                sleepHours: 10, walkingMinutes: 5, workoutMinutes: 0, workoutHR: 0, workoutKind: .other,
                workoutOnFoot: false, workoutDaysPerWeek: 0, restingHR: 72, range: 1.15...1.40),
    ]

    func testEveryPersonaLandsInItsRange() throws {
        for persona in Self.personas {
            let value = try Self.multiple(persona, peakMET: 10)
            XCTAssertTrue(persona.range.contains(value),
                          "\(persona.name): \(value) outside \(persona.range)")
        }
    }
}
