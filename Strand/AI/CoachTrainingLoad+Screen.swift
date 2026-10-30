import Foundation
import StrandAnalytics

/// The Training Load screen's reading (`TrainingLoadPreparation.Prepared`, what `TrainingLoadModel` shows) rendered for
/// the model. Shared with the Android core, which prepares the same reading (`CoreTrainingLoad`).
extension CoachTrainingLoadBrief {
    static func text(_ p: TrainingLoadPreparation.Prepared) -> String {
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

    static func laneLines(_ name: String, unit: String, lane: TrainingLoadPreparation.Lane, verdict: LaneVerdict?,
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
    static func outlookLines(_ outlook: TrainingLoadPreparation.Outlook) -> [String] {
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
}
