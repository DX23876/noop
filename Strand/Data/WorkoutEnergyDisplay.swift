import Foundation
import SwiftUI
import StrandAnalytics
import WhoopStore

// WorkoutEnergyDisplay.swift — one answer for "what did this session cost?", wherever it is shown.
//
// The Workouts list, the workout detail and the coach each held their own `row.energyKcal` and each
// printed a dash when it was nil. A native strength session, a Hevy import and a hand-entered bout
// never carry a figure, so all three showed nothing beside a complete heart-rate curve — reported
// as "the training that u record, when viewed in workouts, it shows no calories burned".
//
// `WorkoutEnergyEstimate` (StrandAnalytics) decides the number and names its provenance. This is the
// app-side half: it supplies the inputs that estimate needs from the app's own stores, and turns the
// result into the text and caption a screen shows. Both halves are shared so a session cannot read
// "–" in the list and "~529 kcal" in its own detail.
//
// **Display only.** Nothing here is written back. An estimate that got persisted would be read as a
// measurement the next time anything looked at the row, and there would be no way left to tell.
enum WorkoutEnergyDisplay {

    /// What one row costs, given the day-scoped inputs a screen loaded once.
    ///
    /// `restingHrByDay` is keyed by local day and looked up by the session's START — the resting rate
    /// sets the activity gate the estimate is measured against, and the wrong day's rate can move the
    /// figure by hundreds of kcal or drop it below the gate entirely.
    ///
    /// `strapKcalByKey` is `Repository.strapSessionEnergy(for:)` for the rows on screen. A session the
    /// strap model covered takes its figure from there, so the tile agrees with the day's energy.
    ///
    /// `peakMETByDay` is `Repository.energyPeakMETByDay`: the aerobic ceiling the day's bucket model
    /// used, so a session priced from its average heart rate is scaled the way its day was.
    static func resolve(_ row: WorkoutRow, profile: UserProfile, hrMax: Double?,
                        restingHrByDay: [String: Double],
                        strapKcalByKey: [String: Double] = [:],
                        peakMETByDay: [String: Double] = [:]) -> WorkoutEnergyEstimate.Resolved? {
        let day = Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval(row.startTs)))
        return WorkoutEnergyEstimate.resolve(
            recordedKcal: row.energyKcal, sport: row.sport,
            durationSeconds: row.durationS ?? Double(max(0, row.endTs - row.startTs)),
            averageHR: row.avgHr, profile: profile, hrMax: hrMax,
            restingHR: restingHrByDay[day], strapKcal: strapKcalByKey[key(row)],
            peakMET: peakMET(on: day, in: peakMETByDay), distanceM: row.distanceM)
    }

    /// How far back a day without its own energy row may borrow the ceiling of an earlier one. Its own
    /// constant rather than the measurement windows (half a year): the ceiling of a day also carries its
    /// activity category, which describes the four weeks before it and nothing older.
    static let peakMETCarryDays = 30

    /// The ceiling in force on `day`: its own, else the newest earlier one within `peakMETCarryDays`.
    /// Nil keeps the session on Keytel, as a day with no ceiling at all would.
    static func peakMET(on day: String, in byDay: [String: Double]) -> Double? {
        if let own = byDay[day] { return own }
        let earliest = WeeklyDigestEngine.addDays(day, -peakMETCarryDays)
        return byDay.filter { $0.key < day && $0.key >= earliest }.max { $0.key < $1.key }?.value
    }

    /// Identity of one session for the strap-energy lookup. The window is part of it: an edited start
    /// or end is a different window, and must not inherit the old one's figure.
    static func key(_ row: WorkoutRow) -> String {
        "\(row.source)|\(row.startTs)|\(row.endTs)|\(row.sport)"
    }

    /// "529 kcal" when it was recorded, "~529 kcal" when it was not. The tilde is the same marker
    /// `EnergyDisplay` uses for a modelled daily total, so one habit reads both.
    static func text(_ resolved: WorkoutEnergyEstimate.Resolved?) -> String? {
        guard let resolved else { return nil }
        let number = Int(resolved.kcal.rounded()).formatted(.number.grouping(.automatic))
        return resolved.isEstimated ? "~\(number)" : number
    }

    /// The line under the figure that says what it is. Nil for a recorded one: a caption on every
    /// session teaches people to stop reading it, and "kcal" is what the tile already says.
    static func caption(_ resolved: WorkoutEnergyEstimate.Resolved?) -> String? {
        switch resolved?.provenance {
        case .recorded, .none: return nil
        case .strapModel:      return String(localized: "est. from strap data")
        case .pace:            return String(localized: "est. from pace")
        case .heartRate:       return String(localized: "est. from avg HR")
        case .metTable:        return String(localized: "est. from activity")
        }
    }

    /// The same claim in a sentence, for the coach's context and for accessibility.
    ///
    /// The provenance travels with the number rather than being dropped for brevity: a bare figure in
    /// a prompt becomes a measurement the moment the model quotes it, and the coach would then tell
    /// someone they burned 529 kcal on the strength of a table of activity names.
    static func spoken(_ resolved: WorkoutEnergyEstimate.Resolved?, averageHR: Int?) -> String? {
        guard let resolved else { return nil }
        let number = Int(resolved.kcal.rounded()).formatted(.number.grouping(.automatic))
        switch resolved.provenance {
        case .recorded:
            return "\(number) kcal"
        case .strapModel:
            return String(localized: "~\(number) kcal, estimated from the strap's heart rate and movement")
        case .pace:
            return String(localized: "~\(number) kcal, estimated from the session's distance and duration")
        case .heartRate:
            let hr = averageHR.map { " of \($0) bpm" } ?? ""
            return String(localized: "~\(number) kcal, estimated from the average heart rate\(hr)")
        case .metTable:
            return String(localized: "~\(number) kcal, estimated from the activity's published cost")
        }
    }
}

/// A pending request to rewrite NOOP's workouts in Apple Health from a given time.
///
/// The regular write-back covers the last 14 days. When stored session energy is corrected further back
/// (recipes AI-13/AI-14), the Health copies of those sessions would keep the old figures, and every app reading
/// Health would keep quoting them. The request is a timestamp in UserDefaults because the correction runs
/// in shared analysis code while the writer is the iOS-only Health bridge; the bridge widens its next
/// workout pass to reach it and clears the request once that pass has written.
enum HealthWorkoutRewrite {
    static let key = "health.workoutRewriteFromTs"

    /// Asks for a rewrite from `ts`, keeping an earlier pending request if there is one.
    static func request(from ts: Int) {
        let pending = UserDefaults.standard.object(forKey: key) as? Int
        UserDefaults.standard.set(min(ts, pending ?? ts), forKey: key)
    }

    /// The pending start, if any.
    static var pendingFrom: Int? { UserDefaults.standard.object(forKey: key) as? Int }

    /// Clears the request, once a pass reaching `from` has written.
    static func complete(through from: Int) {
        guard let pending = pendingFrom, from <= pending else { return }
        UserDefaults.standard.removeObject(forKey: key)
    }
}
