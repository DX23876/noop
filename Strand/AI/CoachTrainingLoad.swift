import Foundation
import StrandAnalytics

/// The Training Load lanes as the Coach reads them: `get_training_load`, and the lane lines in the
/// Readiness block that replaced the acute:chronic ratio (P2).
///
/// Everything here is a rendering of values the Training Load screen already computed
/// (`TrainingLoadModel.snapshot`, `Repository.readinessLoadContext`). Nothing is classified again, so
/// the Coach cannot describe a band or a verdict the screen does not show. English only: this is model
/// context, never shown to the wearer.
enum CoachTrainingLoadBrief {

    static func bandPhrase(_ band: RelativeLoadBand) -> String {
        switch band {
        case .below: return "below usual"
        case .usual: return "about usual"
        case .higher: return "above usual"
        case .muchHigher: return "well above usual"
        }
    }

    static func percent(_ value: Double) -> String {
        String(format: "%+.0f %%", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    static func number(_ value: Double) -> String {
        String(format: value >= 100 ? "%.0f" : "%.1f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    /// Why a lane has no band, or why its band is capped — the guard, stated rather than silent.
    static func guardNote(_ guardState: LaneGuard, band: RelativeLoadBand?) -> String? {
        switch guardState {
        case .none: return band == nil ? "no comparison yet (not enough history)" : nil
        case .tooFewSessions: return "no band: fewer than \(LaneEngine.minimumBaselineSessions) sessions in the baseline"
        case .lowVolumeCap: return "capped at 'above usual': the baseline is under the WHO weekly minimum"
        }
    }

    // MARK: - Readiness block

    /// One line per lane for the Readiness block, or nothing when the lanes have not been read yet.
    static func readinessLines(_ context: ReadinessLoadContext?) -> [String] {
        guard let context else { return [] }
        var lines = ["Training load lanes (last 7 days vs the wearer's own usual; units never mixed):"]
        for lane in context.lanes {
            var parts: [String] = []
            if let band = lane.band { parts.append(bandPhrase(band)) }
            if let change = lane.percentChange { parts.append(percent(change)) }
            if let note = guardNote(lane.guardState, band: lane.band) { parts.append(note) }
            if let monotony = lane.monotony {
                parts.append("monotony " + String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), monotony))
            }
            lines.append("  \(lane.kind.rawValue.capitalized): " + parts.joined(separator: ", "))
        }
        return lines
    }

    // MARK: - get_training_load

    static func text(_ p: TrainingLoadModel.Prepared) -> String {
        var lines = ["TRAINING LOAD (the app's Training Load screen; three lanes, each in its own unit — never add "
                     + "or convert them)"]
        lines.append("Statement: " + statement(p.statement))
        lines.append("")
        lines.append(contentsOf: laneLines("Strength", unit: "weighted working sets", lane: p.strength,
                                           verdict: p.strengthVerdict,
                                           coverage: "RPE-rated working sets"))
        lines.append("  performance evidence (e1RM of the main lifts): \(evidence(LaneEvidence(p.response.direction)))")
        lines.append(contentsOf: laneLines("Cardio", unit: "heart-rate load (TRIMP)", lane: p.cardio,
                                           verdict: p.cardioVerdict,
                                           coverage: "sessions priced from heart rate"))
        lines.append("  performance evidence (\(cardioSource(p.cardioEvidence.source))): "
                     + evidence(p.cardioEvidence.evidence))
        lines.append(contentsOf: laneLines("Session load", unit: "RPE × minutes", lane: p.session,
                                           verdict: nil, coverage: "rated sessions"))
        lines.append("")
        lines.append(contentsOf: outlookLines(p.outlook))
        lines.append("Recovery over the last 7 nights: \(p.recovery.state.rawValue)")
        if let sustained = p.sustained {
            lines.append("LASTING OVERLOAD: \(sustained.lanes.map(\.rawValue).joined(separator: " and ")) well above "
                         + "usual for \(sustained.weeks) week-ends with performance falling and recovery strained.")
        }
        if !p.history.isEmpty {
            lines.append("Week-end bands, oldest first:")
            lines.append("  strength: " + p.history.map { $0.strength.map(bandPhrase) ?? "-" }.joined(separator: ", "))
            lines.append("  cardio: " + p.history.map { $0.cardio.map(bandPhrase) ?? "-" }.joined(separator: ", "))
        }
        lines.append("")
        lines.append("How to read this: bands compare with the wearer's own usual, not with anyone else. A verdict "
                     + "(productive, overreaching, …) exists only where performance evidence supports it; where a "
                     + "lane says 'load only', describe the load and do not claim it is working or harmful. A lane "
                     + "without a band has too little history — say so instead of guessing.")
        return lines.joined(separator: "\n")
    }

    static func laneLines(_ name: String, unit: String, lane: TrainingLoadModel.Lane, verdict: LaneVerdict?,
                          coverage: String) -> [String] {
        var head = "\(name) (\(unit)): last 7 days \(number(lane.sevenDayTotal))"
        if lane.isLowerBound { head += " (lower bound: some days could not be measured)" }
        var lines = [head]
        var comparison: [String] = []
        if let change = lane.trend?.percentChange { comparison.append("vs usual \(percent(change))") }
        if let band = lane.reading?.band {
            let edges = lane.reading?.thresholds?.isPersonal == true ? "personal range" : "provisional edges"
            comparison.append("band: \(bandPhrase(band)) (\(edges))")
        }
        if let reading = lane.reading, let note = guardNote(reading.guardState, band: reading.band) {
            comparison.append(note)
        }
        if let weekOverWeek = lane.weekOverWeek { comparison.append("week over week \(percent(weekOverWeek))") }
        if let monotony = lane.distribution?.monotony {
            comparison.append("monotony " + String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), monotony))
        }
        if !comparison.isEmpty { lines.append("  " + comparison.joined(separator: " · ")) }
        if let verdict { lines.append("  verdict: " + verdictText(verdict)) }
        if lane.possibleCount > 0 {
            lines.append("  coverage: \(lane.measuredCount) of \(lane.possibleCount) \(coverage)")
        }
        return lines
    }

    /// Room left today and the settling day, per lane — where the edges are, not a target.
    static func outlookLines(_ outlook: TrainingLoadModel.Outlook) -> [String] {
        var lines: [String] = []
        for (name, unit, room, settles) in [("Strength", "weighted sets", outlook.strengthRoom, outlook.strengthSettles),
                                            ("Cardio", "TRIMP", outlook.cardioRoom, outlook.cardioSettles)] {
            var parts: [String] = []
            if let room {
                parts.append("room today \(number(room.beforeAbove)) \(unit) before above usual"
                             + (room.beforeWellAbove.map { ", \(number($0)) before well above usual" } ?? ""))
            }
            if let settles { parts.append("back to usual on \(settles) if every day from now is rest") }
            if !parts.isEmpty { lines.append("\(name): " + parts.joined(separator: "; ")) }
        }
        guard !lines.isEmpty else { return [] }
        return ["Room and settling (edges of the usual week, not targets):"] + lines.map { "  " + $0 }
    }

    /// What a planned cardio session would add to the lane, against today's room. Descriptive: it says
    /// where the session lands, not whether to do it.
    static func plannedCardioLine(low: Double, high: Double, room: LaneHeadroom?) -> String {
        let load = "This session adds about \(number(low))–\(number(high)) TRIMP to the cardio lane (Banister, "
            + "from the zone's heart-rate range)."
        guard let room else {
            return load + " The lane has no band yet, so there is no room to check it against."
        }
        let placement: String
        if high <= room.beforeAbove {
            placement = "It fits inside the usual week (room before above usual: \(number(room.beforeAbove)))."
        } else if let well = room.beforeWellAbove, high <= well {
            placement = "It would take the week above usual (room before above usual: \(number(room.beforeAbove)), "
                + "before well above usual: \(number(well)))."
        } else if let well = room.beforeWellAbove {
            placement = "It would take the week well above usual (room before well above usual: \(number(well)))."
        } else {
            placement = "It would take the week above usual (room before above usual: \(number(room.beforeAbove)))."
        }
        return load + " " + placement + " This describes load only; recovery and readiness decide whether it is wise."
    }

    static func verdictText(_ verdict: LaneVerdict) -> String {
        switch verdict {
        case .status(let status): return status.rawValue
        case .loadOnly(let band): return "load only — \(bandPhrase(band)), no performance evidence for a judgement"
        }
    }

    static func evidence(_ evidence: LaneEvidence) -> String {
        switch evidence {
        case .rising: return "rising"
        case .unclear: return "unclear"
        case .falling: return "falling"
        case .none: return "none"
        }
    }

    static func cardioSource(_ source: CardioEvidenceSource) -> String {
        switch source {
        case .appleVO2max: return "fresh Apple Watch VO2max"
        case .heartRateEfficiency: return "heart-rate efficiency of the main sport"
        case .none: return "no usable source"
        }
    }

    static func statement(_ statement: TrainingStatusModel.TrainingStatement) -> String {
        switch statement {
        case .noHistory: return "not enough history for either lane yet"
        case .laneOnly(let lane, let verdict): return "only \(lane.rawValue) has a band: \(verdictText(verdict))"
        case .aligned(let verdict): return "both lanes agree: \(verdictText(verdict))"
        case .oneBehind(let lane): return "\(lane.rawValue) is below usual while the other lane holds"
        case .split(let low, let high, let severity):
            return "the lanes split (\(severity.rawValue)): \(low.rawValue) below usual, \(high.rawValue) at or above it"
        case .excessive(let lane, let strained):
            return "\(lane.rawValue) is well above usual" + (strained ? " and recovery is strained" : "")
        case .bothExcessive(let strained):
            return "both lanes are well above usual" + (strained ? " and recovery is strained" : "")
        case .spinning(let lane, let otherHigh):
            return "\(lane.rawValue) is trained at or above usual while its performance falls"
                + (otherHigh ? "; the other lane is high too" : "")
        case .bothSpinning: return "both lanes are trained at or above usual while performance falls"
        case .strainedRecovery: return "recovery is strained"
        }
    }
}

extension AICoachEngine {
    /// `get_training_load`: the Training Load screen's own reading, rendered for the model.
    func trainingLoadTool() async -> String {
        CoachTrainingLoadBrief.text(await TrainingLoadModel.snapshot(repo: repo).prepared)
    }
}
