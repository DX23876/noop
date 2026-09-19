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
    static func resolve(_ row: WorkoutRow, profile: UserProfile, hrMax: Double?,
                        restingHrByDay: [String: Double]) -> WorkoutEnergyEstimate.Resolved? {
        let day = Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval(row.startTs)))
        return WorkoutEnergyEstimate.resolve(
            recordedKcal: row.energyKcal, sport: row.sport,
            durationSeconds: row.durationS ?? Double(max(0, row.endTs - row.startTs)),
            averageHR: row.avgHr, profile: profile, hrMax: hrMax,
            restingHR: restingHrByDay[day])
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
        case .heartRate:
            let hr = averageHR.map { " of \($0) bpm" } ?? ""
            return String(localized: "~\(number) kcal, estimated from the average heart rate\(hr)")
        case .metTable:
            return String(localized: "~\(number) kcal, estimated from the activity's published cost")
        }
    }
}
