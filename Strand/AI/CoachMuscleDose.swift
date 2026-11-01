import Foundation
import StrandAnalytics
import WhoopStore

/// Weekly working sets per muscle group for the Coach, set against the research band the Lift Log uses.
///
/// The strength block already lists each primary muscle's working sets over 28 days. What the Coach could
/// not do with that alone is answer "is that a little or a lot": a 28-day count is not the unit training is
/// prescribed in, and nothing told it what the research associates with growth. This turns the same tally
/// into fractional sets per week (a secondary muscle's set counts half, the operationalisation the reference
/// doses were derived under, see `LiftMetrics.muscleCounts`) and names `LiftMetrics.ReferenceDose` with its
/// source, as a band and never as a prescription. Idea from mohamedchnafy-ds/noop (82904f9c6).
enum CoachMuscleDose {
    /// The lines for the strength block, or [] when no set was attributed to a muscle. `days` is the window
    /// the tally covers.
    static func lines(primary: [HevyMuscleGroup: Int], secondary: [HevyMuscleGroup: Int], days: Int) -> [String] {
        guard days > 0 else { return [] }
        let weeks = Double(days) / 7
        var fractional: [HevyMuscleGroup: Double] = [:]
        for (group, n) in primary { fractional[group, default: 0] += Double(n) * LiftMuscle.directSetCredit }
        for (group, n) in secondary { fractional[group, default: 0] += Double(n) * LiftMuscle.indirectSetCredit }
        let perWeek = fractional.filter { ![.other, .cardio, .fullBody].contains($0.key) && $0.value > 0 }
            .mapValues { $0 / weeks }
            .sorted { $0.value == $1.value ? $0.key.rawValue < $1.key.rawValue : $0.value > $1.value }
        guard !perWeek.isEmpty else { return [] }
        let list = perWeek.map { "\($0.key.label) \(String(format: "%.1f", $0.value))" }.joined(separator: ", ")
        return [
            "Fractional working sets per muscle per week, same \(days) days (a secondary muscle's set counts half): \(list).",
            "Research band for these (2025 Sports Medicine dose-response meta-regression, fractional counting; "
                + "a population band, not a prescription for this user): below about "
                + "\(trim(LiftMetrics.ReferenceDose.hypertrophyMinimumSetsPerWeek)) sets per week growth is not "
                + "reliably detectable, more keeps helping with diminishing returns; strength improves from "
                + "\(trim(LiftMetrics.ReferenceDose.strengthMinimumSetsPerWeek)) set per week and added volume "
                + "stops reliably helping strength near \(trim(LiftMetrics.ReferenceDose.strengthPlateauSetsPerWeek)).",
        ]
    }

    private static func trim(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}
