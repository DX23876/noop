import Foundation

// EffectRanker.swift — the unified, LAG-AWARE "what moves your Charge" ranker.
//
// Pure, deterministic, DB-free. Generalises ActivityCostEngine's single-sport D+1 to
// EVERY logged journal behaviour against EVERY daily outcome, and searches a small fixed
// lag set so it can tell "same day" from "shows up the next morning."
//
// For each (behaviour b, outcome o, lag L ∈ {0, +1, +2}):
//   1. behaviourDays = the day keys b was logged on (dose ≥ 1; callers pass the set).
//   2. Pair behaviour day D with outcome day D+L by SHIFTING the outcome map back by L —
//      i.e. re-key outcome[D+L] under D via CorrelationEngine.shiftDay(day, by: -L). This is
//      exactly the alignment ActivityCostEngine does for D+1, parameterised over the lag and
//      reusing the same fixed-UTC day arithmetic, so behaviour day D is compared with the
//      outcome that landed L days later.
//   3. Run the EXISTING BehaviorInsights.effect on the shifted outcome map → meanWith,
//      meanWithout, delta, cohensD, Welch pApprox, significant (already gated at
//      min(nWith, nWithout) ≥ 5).
//   4. FDR: every gated (b, L) test of one `rank` run forms ONE family; Benjamini–Hochberg at
//      q = 0.10 over their Welch p-values gives `fdrSignificant`/`adjustedP` (the verdict shown).
//   5. Keep, per (b, o), the lag L* with the LARGEST |cohensD| among lags whose effect
//      computed AND cleared the significance group gate, carrying L* as the lead/lag.
//
// HONESTY (effect-size first, not stargazing): the primary signal is the effect SIZE +
// n + a ScoreConfidence tier, never a bare "significant" stamp. The lag search is capped
// at the small fixed set {0,1,2} so the comparison count stays bounded and explainable; we
// never claim a behaviour "causes" anything — only that it lines up with a change.
//
// Output: one RankedEffect per (b, o) that produced a usable lag, ranked with the same rule
// as BehaviorInsights.rank (significant first, |cohensD| desc, stable tiebreak), so the feed
// matches the existing Behaviour Effects ordering exactly. Self-contained except for the two
// reused primitives, so the Kotlin twin is line-for-line.
//
// (Spec: 2026-06-19-v5-insights-correlation-engine-design.md — "Lag-aware effect ranking".)

// MARK: - Result

/// One ranked, lag-aware behaviour→outcome effect: the best lag's BehaviorEffect plus the
/// lead/lag it was found at and a confidence tier from the paired-day count.
public struct RankedEffect: Equatable, Sendable {
    /// The behaviour label (e.g. "Alcohol").
    public let behavior: String
    /// The outcome metric label (e.g. "Charge").
    public let outcome: String
    /// The lag (in days) at which the strongest honest effect was found: 0 = same day,
    /// +1 = the next morning, +2 = two mornings later.
    public let lag: Int
    /// The measured effect at `lag` (means, delta, Cohen's d, Welch p, significant).
    public let effect: BehaviorEffect
    /// Per-result certainty tier from the smaller group's size at the chosen lag.
    public let confidence: ScoreConfidence
    /// Benjamini–Hochberg adjusted p-value across every behaviour×lag test of the run that
    /// produced this row. `nil` for a row built outside `rank` (no family to correct over).
    public let adjustedP: Double?
    /// The verdict to show: FDR-significant at q = `EffectRanker.fdrQ` across the whole run.
    /// Rows built outside `rank` fall back to the uncorrected `effect.significant`.
    public let fdrSignificant: Bool

    public init(behavior: String, outcome: String, lag: Int,
                effect: BehaviorEffect, confidence: ScoreConfidence,
                adjustedP: Double? = nil, fdrSignificant: Bool? = nil) {
        self.behavior = behavior
        self.outcome = outcome
        self.lag = lag
        self.effect = effect
        self.confidence = confidence
        self.adjustedP = adjustedP
        self.fdrSignificant = fdrSignificant ?? effect.significant
    }

    /// Plain-English lead/lag chip text, e.g. "same day" / "next morning" / "2 mornings later".
    public var leadLagText: String {
        switch lag {
        case 0: return "same day"
        case 1: return "next morning"
        default: return "\(lag) mornings later"
        }
    }

    /// The sign-aware sentence for this row, reusing BehaviorInsights' renderer plus the
    /// lead/lag clause so each card reads "…, showing up the next morning."
    public func sentence() -> String {
        let base = BehaviorInsights.sentence(effect)
        // Drop the trailing period, append the lead/lag, restore it.
        let trimmed = base.hasSuffix(".") ? String(base.dropLast()) : base
        return "\(trimmed) (\(leadLagText))."
    }
}

// MARK: - Engine

public enum EffectRanker {

    /// The fixed, bounded lag set searched per (behaviour, outcome). Kept small and explicit
    /// — not a fitted VAR — so the multiple-comparison count stays bounded and honest at small n.
    public static let lagSet: [Int] = [0, 1, 2]

    /// Paired-day count below which a chosen lag's confidence is `.calibrating` (too thin to
    /// shout). This equals BehaviorInsights' significance group gate, so a row that clears the
    /// gate is never `.calibrating`.
    public static let calibratingBelow: Int = BehaviorInsights.minGroupForSignificance  // 5
    /// Paired-day count at/above which a chosen lag's confidence is `.solid` (else `.building`).
    public static let solidPairs: Int = 10
    /// False-discovery rate for the Benjamini–Hochberg correction over one `rank` run. Every habit is
    /// tested at three lags, so without it a single "clear" row among many habits can still be chance.
    /// From bitsandben/zoop (e6764c16d).
    public static let fdrQ: Double = 0.10

    // MARK: - Rank

    /// Rank every behaviour against one outcome across the lag set, keeping each behaviour's
    /// best lag. Mirrors BehaviorInsights.rank's ordering on the surviving rows.
    ///
    /// - Parameters:
    ///   - behaviors: per behaviour name, the SET of "yyyy-MM-dd" days it was logged (dose ≥ 1).
    ///   - outcomeByDay: the daily outcome series keyed "yyyy-MM-dd" (e.g. Charge 0–100).
    ///   - outcome: the outcome label carried onto each RankedEffect (e.g. "Charge").
    /// - Returns: one RankedEffect per behaviour that produced a usable lag, ranked
    ///   significant-first, |cohensD| desc, then behaviour name asc. Behaviours with no
    ///   computable lag are dropped.
    public static func rank(behaviors: [String: Set<String>],
                            controls: [String: Set<String>],
                            outcomeByDay: [String: Double],
                            outcome: String) -> [RankedEffect] {
        // Family = EVERY gated (behaviour, lag) test of this run, not just each behaviour's
        // winning lag: choosing the best of three lags is itself a selection step.
        var perBehavior: [(name: String, cands: [(lag: Int, effect: BehaviorEffect)])] = []
        var familyP: [Double] = []
        // Sort behaviour names so the build order is deterministic regardless of dict order.
        for name in behaviors.keys.sorted() {
            // Absent from `controls` means no control group, which yields nothing — see
            // BehaviorInsights.effect. Failing closed is deliberate: a caller that forgets loses the
            // insight rather than getting one measured against every unlogged day.
            let cands = lagCandidates(behaviorDays: behaviors[name]!, controlDays: controls[name] ?? [],
                                      outcomeByDay: outcomeByDay, behavior: name, outcome: outcome)
            perBehavior.append((name, cands))
            familyP.append(contentsOf: cands.map { $0.effect.pApprox })
        }
        let adjusted = benjaminiHochbergAdjusted(familyP)
        let passes = benjaminiHochberg(pValues: familyP, q: fdrQ)
        var rows: [RankedEffect] = []
        var offset = 0
        for (name, cands) in perBehavior {
            defer { offset += cands.count }
            guard let best = pickBest(cands),
                  let idx = cands.firstIndex(where: { $0.lag == best.lag }) else { continue }
            let pairs = Swift.min(best.effect.nWith, best.effect.nWithout)
            rows.append(RankedEffect(behavior: name, outcome: outcome, lag: best.lag,
                                     effect: best.effect, confidence: confidence(forPairs: pairs),
                                     adjustedP: adjusted[offset + idx],
                                     fdrSignificant: passes[offset + idx]))
        }
        return sorted(rows)
    }

    // MARK: - Benjamini–Hochberg FDR

    /// Benjamini–Hochberg step-up procedure. Returns, per input p-value (same order), whether it is
    /// rejected (a discovery) at false-discovery rate `q`: sort ascending, find the largest rank k with
    /// p(k) <= k/m * q, and reject every hypothesis ranked <= k. Ties share the verdict of the tied
    /// group, so equal p-values are never split. Non-finite p-values are never rejected but still
    /// count towards m.
    public static func benjaminiHochberg(pValues: [Double], q: Double) -> [Bool] {
        let m = pValues.count
        guard m > 0 else { return [] }
        let order = pValues.indices.sorted { pValues[$0] < pValues[$1] }
        var cutoff = -1   // largest 0-based sorted position that passes
        for (pos, i) in order.enumerated() where pValues[i].isFinite {
            if pValues[i] <= Double(pos + 1) / Double(m) * q { cutoff = pos }
        }
        var out = [Bool](repeating: false, count: m)
        guard cutoff >= 0 else { return out }
        let cutP = pValues[order[cutoff]]
        for i in pValues.indices where pValues[i].isFinite && pValues[i] <= cutP { out[i] = true }
        return out
    }

    /// BH-adjusted p-values (q-values), same order as the input, monotone and capped at 1. A test is
    /// rejected at level q exactly when its adjusted value is <= q.
    public static func benjaminiHochbergAdjusted(_ pValues: [Double]) -> [Double] {
        let m = pValues.count
        guard m > 0 else { return [] }
        let order = pValues.indices.sorted { pValues[$0] < pValues[$1] }
        var out = [Double](repeating: 1, count: m)
        var running = 1.0
        for pos in stride(from: m - 1, through: 0, by: -1) {
            let i = order[pos]
            guard pValues[i].isFinite else { continue }
            running = Swift.min(running, pValues[i] * Double(m) / Double(pos + 1))
            out[i] = Swift.min(1, running)
        }
        return out
    }

    /// Find the best-lag RankedEffect for ONE behaviour against ONE outcome, or nil when no
    /// lag in `lagSet` yields a computable effect that clears the group gate.
    public static func bestLag(behaviorDays: Set<String>,
                               controlDays: Set<String>,
                               outcomeByDay: [String: Double],
                               behavior: String,
                               outcome: String) -> RankedEffect? {
        let cands = lagCandidates(behaviorDays: behaviorDays, controlDays: controlDays,
                                  outcomeByDay: outcomeByDay, behavior: behavior, outcome: outcome)
        guard let chosen = pickBest(cands) else { return nil }
        let pairs = Swift.min(chosen.effect.nWith, chosen.effect.nWithout)
        return RankedEffect(behavior: behavior, outcome: outcome, lag: chosen.lag,
                            effect: chosen.effect, confidence: confidence(forPairs: pairs))
    }

    /// Every lag in `lagSet` whose effect computed and cleared the group gate (a lag only competes if
    /// both sides reach the significance minimum, so a 2-day lag can't win on a fluke).
    static func lagCandidates(behaviorDays: Set<String>, controlDays: Set<String>,
                              outcomeByDay: [String: Double], behavior: String,
                              outcome: String) -> [(lag: Int, effect: BehaviorEffect)] {
        var out: [(lag: Int, effect: BehaviorEffect)] = []
        for lag in lagSet {
            let shifted = shiftedOutcome(outcomeByDay, byLag: lag)
            guard let e = BehaviorInsights.effect(behaviorDays: behaviorDays,
                                                  controlDays: controlDays,
                                                  outcomeByDay: shifted,
                                                  behavior: behavior,
                                                  outcome: outcome) else { continue }
            guard Swift.min(e.nWith, e.nWithout) >= BehaviorInsights.minGroupForSignificance else { continue }
            out.append((lag, e))
        }
        return out
    }

    /// Largest |cohensD| wins; ties break to the SMALLER lag (prefer same-day / shorter lead over a
    /// longer one when the effect size is identical).
    static func pickBest(_ cands: [(lag: Int, effect: BehaviorEffect)]) -> (lag: Int, effect: BehaviorEffect)? {
        var best: (lag: Int, effect: BehaviorEffect)?
        for c in cands {
            if let cur = best {
                let better = abs(c.effect.cohensD) > abs(cur.effect.cohensD)
                    || (abs(c.effect.cohensD) == abs(cur.effect.cohensD) && c.lag < cur.lag)
                if better { best = c }
            } else { best = c }
        }
        return best
    }

    // MARK: - Lag alignment

    /// Re-key the outcome series so behaviour day D is paired with the outcome that landed
    /// `lag` days later: out'[D] = out[D+lag]. We move the VALUE from key D+lag back to key D
    /// by shifting each existing key BACKWARD by `lag` (shiftDay(day, by: -lag)). Then a plain
    /// BehaviorInsights split on behaviour day D reads the D+lag outcome — the same join
    /// ActivityCostEngine performs for D+1, generalised. `lag == 0` is the identity map.
    static func shiftedOutcome(_ outcomeByDay: [String: Double], byLag lag: Int) -> [String: Double] {
        if lag == 0 { return outcomeByDay }
        var out: [String: Double] = [:]
        out.reserveCapacity(outcomeByDay.count)
        for (day, value) in outcomeByDay {
            // The outcome ON day `day` belongs to behaviour day `day - lag`.
            if let behaviourKey = CorrelationEngine.shiftDay(day, by: -lag) {
                out[behaviourKey] = value
            }
        }
        return out
    }

    // MARK: - Confidence

    /// Confidence from the smaller group's paired-day count: below the group gate →
    /// `.calibrating`; gate…<solidPairs → `.building`; ≥ solidPairs → `.solid`.
    static func confidence(forPairs pairs: Int) -> ScoreConfidence {
        if pairs < calibratingBelow { return .calibrating }
        return pairs >= solidPairs ? .solid : .building
    }

    // MARK: - Ranking

    /// Stable rank matching BehaviorInsights.rank: significant first, |cohensD| desc, then
    /// behaviour name ascending.
    static func sorted(_ rows: [RankedEffect]) -> [RankedEffect] {
        rows.sorted { a, b in
            if a.fdrSignificant != b.fdrSignificant { return a.fdrSignificant }
            let la = abs(a.effect.cohensD), lb = abs(b.effect.cohensD)
            if la != lb { return la > lb }
            return a.behavior < b.behavior
        }
    }
}
