import Foundation
import StrandAnalytics

/// What a training choice actually costs you — computed from YOUR history, not guessed by a model.
///
/// This is what turns swapping a session from a calendar edit into a coaching moment. Swap the Zone 2
/// ride for CrossFit and the app can say, from your own data, that sessions like that usually cost you
/// ~18 Charge points and take ~2 days to bounce back — where the ride costs 6 and one. Then it gets out
/// of the way, because it's your training.
///
/// Two existing engines do the work; nothing new is invented here:
///   • `ActivityCostEngine` — per-sport Charge cost + bounce-back days, from your own tagged sessions.
///   • `RecoveryForecaster` — tomorrow-morning Charge ± band, given today's effort and tonight's sleep.
///
/// INFORMS, NEVER BLOCKS. There is no verdict type here on purpose: no `.tooRisky`, no gate. The user
/// is told what their own history says and then makes the call. `ScoreConfidence` rides along so a
/// thin-evidence number is never presented with the same certainty as a well-backed one.
enum PlanConsequence {

    /// What we can say about one candidate session.
    struct Outlook: Equatable {
        let sport: String
        /// Charge points this sport usually costs the next morning (positive = costs you), from your
        /// own history. nil when there aren't enough tagged sessions to say honestly.
        let chargeCost: Double?
        /// Days it usually takes to get back to baseline. nil when unknown or it never dips.
        let bounceBackDays: Int?
        /// How well-backed the cost figure is.
        let costConfidence: ScoreConfidence?
        /// Projected tomorrow-morning Charge if this session happens. nil on a cold start.
        let forecastCharge: Double?
        /// ± band on the projection.
        let forecastBand: Double?
        /// How many of your own sessions the cost is based on.
        let sampleCount: Int?

        /// Plain-English line, degrading honestly as evidence thins out.
        func sentence() -> String {
            var parts: [String] = []
            if let cost = chargeCost, let n = sampleCount {
                let points = Int(abs(cost).rounded())
                if abs(cost) < ActivityCostEngine.barelyMovesPoints {
                    parts.append("\(sport) barely moves your next-day Charge (from \(n) of your sessions)")
                } else {
                    let dir = cost >= 0 ? "costs you" : "lifts"
                    var s = "\(sport) usually \(dir) about \(points) Charge point\(points == 1 ? "" : "s") "
                        + "the next morning"
                    if let days = bounceBackDays {
                        s += " and takes about \(days) day\(days == 1 ? "" : "s") to bounce back"
                    }
                    s += " (from \(n) of your sessions)"
                    parts.append(s)
                }
            } else {
                parts.append("I don't have enough of your own \(sport) sessions yet to say what it costs you")
            }
            if let charge = forecastCharge, let band = forecastBand {
                parts.append(String(format: "tomorrow projects around %.0f ± %.0f", charge, band))
            }
            return parts.joined(separator: "; ") + "."
        }
    }

    /// A side-by-side when the user swaps one session for another.
    struct Comparison: Equatable {
        let from: Outlook
        let to: Outlook

        /// The honest framing: what changes, then explicitly hand the decision back.
        func sentence() -> String {
            "\(to.sentence()) For comparison: \(from.sentence()) Your call — I'll plan around whichever "
                + "you pick."
        }
    }

    /// The inputs both engines need, assembled once by the caller (see `AICoachEngine.planInputs()`).
    struct Inputs: Equatable {
        /// Day-key → Charge, for the cost engine's baseline.
        var recoveryByDay: [String: Double]
        /// Sport → the set of day-keys it was tagged on.
        var activityDaysBySport: [String: Set<String>]
        /// Recent Charge, oldest→newest, for the forecaster.
        var recentCharge: [Double]
        /// Recent Effort, oldest→newest.
        var recentEffort: [Double]
        /// The user's typical sleep, for the forecast's adequacy term.
        var typicalSleepHours: Double
        /// Nights backing the sleep figure — drives the forecast's confidence tier.
        var sleepNights: Int

        init(recoveryByDay: [String: Double] = [:],
             activityDaysBySport: [String: Set<String>] = [:],
             recentCharge: [Double] = [],
             recentEffort: [Double] = [],
             typicalSleepHours: Double = RecoveryForecaster.defaultNeedHours,
             sleepNights: Int = 0) {
            self.recoveryByDay = recoveryByDay
            self.activityDaysBySport = activityDaysBySport
            self.recentCharge = recentCharge
            self.recentEffort = recentEffort
            self.typicalSleepHours = typicalSleepHours
            self.sleepNights = sleepNights
        }
    }

    // MARK: - Entry points

    /// What one session is likely to cost. `plannedEffort` feeds the forecast's strain term; pass the
    /// session's target Effort, or nil to leave the projection load-neutral.
    static func outlook(sport: String,
                        plannedEffort: Double?,
                        plannedSleepHours: Double? = nil,
                        inputs: Inputs) -> Outlook {
        let costs = ActivityCostEngine.evaluate(activityDaysBySport: inputs.activityDaysBySport,
                                                recoveryByDay: inputs.recoveryByDay)
        // Match case-insensitively: the sport vocabulary comes from the user's own history, and "Cycling"
        // and "cycling" are the same session to a human.
        let match = costs.first { $0.sport.lowercased() == sport.lowercased() }
        let forecast = RecoveryForecaster.forecast(
            recentCharge: inputs.recentCharge,
            recentEffort: inputs.recentEffort,
            todayEffort: plannedEffort,
            plannedSleepHours: plannedSleepHours ?? inputs.typicalSleepHours,
            needHours: inputs.typicalSleepHours,
            needNights: inputs.sleepNights)
        return Outlook(sport: sport,
                       chargeCost: match?.delta,
                       bounceBackDays: match?.daysToBaseline,
                       costConfidence: match?.confidence,
                       forecastCharge: forecast?.charge,
                       forecastBand: forecast?.band,
                       sampleCount: match?.n)
    }

    /// Swapping `from` for `to`: both outlooks, side by side.
    static func compare(from: String, fromEffort: Double?,
                        to: String, toEffort: Double?,
                        plannedSleepHours: Double? = nil,
                        inputs: Inputs) -> Comparison {
        Comparison(
            from: outlook(sport: from, plannedEffort: fromEffort,
                          plannedSleepHours: plannedSleepHours, inputs: inputs),
            to: outlook(sport: to, plannedEffort: toEffort,
                        plannedSleepHours: plannedSleepHours, inputs: inputs))
    }

    /// The free-standing "what if" — the thing that turns the coach from a describer into a simulator.
    /// Returns nil on a cold start rather than a made-up number.
    static func simulate(todayEffort: Double?, plannedSleepHours: Double, inputs: Inputs) -> String? {
        guard let f = RecoveryForecaster.forecast(
            recentCharge: inputs.recentCharge,
            recentEffort: inputs.recentEffort,
            todayEffort: todayEffort,
            plannedSleepHours: plannedSleepHours,
            needHours: inputs.typicalSleepHours,
            needNights: inputs.sleepNights) else { return nil }
        var s = String(format: "With effort %@ today and %.1f h sleep tonight, tomorrow's Charge "
                       + "projects around %.0f (± %.0f, baseline %.0f).",
                       todayEffort.map { String(format: "%.0f", $0) } ?? "unspecified",
                       plannedSleepHours, f.charge, f.band, f.baseline)
        if f.confidence != .solid {
            s += " Confidence: \(f.confidence.rawValue) — treat it as a direction, not a promise."
        }
        return s
    }
}
