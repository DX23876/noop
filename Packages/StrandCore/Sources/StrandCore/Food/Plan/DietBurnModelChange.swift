import Foundation

/// What a plan does when the strap's energy model changes under it (owner decisions 2026-11-27, Q11 and Q30).
///
/// Forge's weekly adjustments (`DietPlan.adjustmentKcal`) were made against the old burn and partly made up for
/// it: the v10 model adds the everyday share of awake still time the old one priced as lying in bed, so
/// adjustments that raised the goal for faster loss than planned would count that twice. A plan whose burn comes
/// from the strap therefore starts its adjustments from zero, remembers the day (the weekly look holds two
/// weeks, `DietAdjust.Hold.burnModelChanged`) and keeps the change in its goal for one note on the Food page.
/// A plan whose burn comes from the scale (`DietPlan.BurnSource.scale`) keeps its adjustments: the strap model
/// never fed it.
public enum DietBurnModelChange {
    /// Days the weekly look holds after the burn model changed.
    public static let holdDays = 14
    /// The first model with an everyday share. A plan last seen under an older one gains it.
    public static let everydayModel = "whoop-bucket-v10"
    /// A change smaller than this is not worth a note.
    public static let noteThresholdKcal: Double = 25

    /// The plan under `current`, or nil when it already is. `everydayMeanKcal` is the everyday share's mean over
    /// the days the plan's burn is the mean of; it is what the goal gains when the plan comes from a model
    /// without it.
    public static func adopt(_ plan: DietPlan, current: String, everydayMeanKcal: Double?, today: String) -> DietPlan? {
        guard plan.burnModelVersion != current else { return nil }
        var next = plan
        next.burnModelVersion = current
        guard plan.burnSource != .scale else { return next }
        let gainsEveryday = current == everydayModel && (plan.burnModelVersion.map { $0 < everydayModel } ?? true)
        let gained = gainsEveryday ? max(0, everydayMeanKcal ?? 0) : 0
        let undone = plan.steering == .manual ? 0 : plan.adjustmentKcal
        next.adjustmentKcal = 0
        next.burnModelChangedDay = today
        let note = gained - undone
        next.burnModelNoteKcal = abs(note) >= noteThresholdKcal && plan.steering != .manual ? note : nil
        return next
    }

    /// Whether `today` is still inside the hold after the plan's model change.
    public static func holds(_ plan: DietPlan, today: String) -> Bool {
        guard let changed = plan.burnModelChangedDay.flatMap(WeightSeries.date(forDay:)),
              let now = WeightSeries.date(forDay: today) else { return false }
        return now.timeIntervalSince(changed) < Double(holdDays) * 86_400
    }
}
