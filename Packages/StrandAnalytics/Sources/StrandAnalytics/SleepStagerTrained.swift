import Foundation
import WhoopProtocol

// Adopted from ayiskakov/noop (`SleepStagerV3`, fitted by its `Tools/SleepTrain`) by @ayiskakov, renamed
// `SleepStagerTrained` here because this fork's `SleepStager.Method.v3` already names a detection change. The
// model and the feature definition are his; this fork only renamed the type and kept the band-window helper
// beside it. It is a Lab option (`SleepStager.StagingRecipe.trained`), never the default.
//
// SleepStagerTrained.swift — the DEFAULT sleep-staging recipe: a stager fitted to human-scored polysomnography.
//
// V2 (`SleepStagerV2`) sets every coefficient by hand from sleep physiology. Every published wrist stager
// that reaches a four-class kappa of 0.5 does the opposite: it fits its per-epoch emissions to PSG labels
// (Fitbit, Oura, Philips, Fonseca et al. 2023, Walch et al. 2019). V3 follows that design, with open data only:
//
//   1. per-epoch features that are all relative to the night itself, so a different strap or fit changes
//      nothing but scale: motion as jerk over the night's own quiet floor and posture change over the night's
//      median change; heart rate as within-night z-scores, percentile ranks and multi-scale variability;
//      time since and until movement; elapsed time; and, when the strap delivered beat intervals, 5-minute
//      heart-rate variability (RMSSD, SDNN, pNN50, LF and HF power, their ratio, the HF peak as a breathing
//      rate, its peakedness, DFA alpha-1) scaled to the night's 5th-95th percentile range;
//   2. two multinomial logistic-regression heads (`SleepStagerTrainedModel.swift`, generated) that turn them into
//      stage posteriors: the base head reads motion and heart rate, the HRV head the beat features as well.
//      When at least half the staged epochs have beat intervals, both run and their log-posteriors are
//      averaged with equal weight; otherwise the base head stages the night alone;
//   3. a Viterbi pass over those posteriors with the stage-transition matrix and start distribution counted
//      from the training hypnograms.
//
// Training: Wearanize+ (88 nights, Empatica E4 wrist + PSG, two human scorers) and PhysioNet sleep-accel
// (31 nights, Apple Watch + PSG). The tool that fits it, its cross-validated agreement per cohort and an
// independent-cohort test are in `Tools/SleepTrain`; `Tools/SleepPSG --section v3` replays this file over
// the same nights. `Tools/SleepTrain/sleeptrain/features.py` is the definition this port is pinned to,
// through the oracle fixture `SleepStagerTrainedOracleTests` loads.
//
// HONEST HEDGING: agreement with PSG is measured on other people's nights and other wrist devices, not on a
// WHOOP strap, for which no public PSG recording exists. The stages remain approximations and are not medical
// advice. V2 and V1 stay selectable.

public enum SleepStagerTrained {

    /// Stage `[start, end]`. DROP-IN for `SleepStagerV2.stageSession`: same signature, same `[StageSegment]`
    /// tiling. `resp` is accepted for parity and not read.
    ///
    /// `sleepWindow` (the band's `SleepStager.bandSleepWindow`) limits staging to the epochs it contains:
    /// features, normalisation and decoding all run over those epochs only, and every other epoch is wake.
    /// That is the view the model was trained on for band nights. Without a window the whole session is staged.
    public static func stageSession(start: Int, end: Int, grav: [GravitySample],
                                    hr: [HRSample], rr: [RRInterval], resp: [RespSample],
                                    sleepWindow: (from: Int, to: Int)? = nil) -> [StageSegment] {
        let epochs = epochStarts(start: start, end: end)
        guard let first = epochs.first, let last = epochs.last else {
            return [StageSegment(start: start, end: end, stage: "light")]
        }
        // Only [first epoch, last epoch + 30) is ever read, so slice every stream to it before keying the
        // memo: the callers pass multi-day streams to every per-night call.
        let lo = first, hi = last + epochS
        let gravW = StagerInput.clip(StagerInput.sortedByTs(grav, { $0.ts }), lo: lo, hi: hi, ts: { $0.ts })
        let hrW = StagerInput.clip(StagerInput.sortedByTs(hr, { $0.ts }), lo: lo, hi: hi, ts: { $0.ts })
        let rrW = StagerInput.clip(StagerInput.sortedByTs(rr, { $0.ts }), lo: lo, hi: hi, ts: { $0.ts })
        let key = StagerInput.Key(start: start, end: end, grav: gravW, hr: hrW, rr: rrW, sleepWindow: sleepWindow)
        return stageCache.value(key) {
            let labels = stageEpochs(epochs: epochs, grav: gravW, hr: hrW, rr: rrW, sleepWindow: sleepWindow,
                                     end: end)
            return StagerInput.tile(epochStarts: epochs, labels: labels, start: start, end: end)
        }
    }

    private static let stageCache = AnalyticsMemoCache<StagerInput.Key, [StageSegment]>(capacity: 24)

    /// Whether a wall-clock recipe epoch lies in the band's sleep window, judged by the one session-grid instant
    /// it contains (the session's cut-short last epoch by the grid epoch it lies in). ayiskakov's
    /// `SleepStagerV2.epochInSleepWindow`, kept here so the shipped V2 stays untouched.
    static func epochInSleepWindow(_ epochStart: Int, _ window: (from: Int, to: Int), end: Int) -> Bool {
        var t = epochStart + ((window.from - epochStart) % 30 + 30) % 30
        if t >= end { t -= 30 }
        return t >= window.from && t < window.to
    }

    /// Stage names in model order.
    static let stages = ["wake", "light", "deep", "rem"]
    static let epochS = 30

    /// Wall-clock 30 s epoch starts covering `[start, end)`, the grid V2 uses.
    static func epochStarts(start: Int, end: Int) -> [Int] {
        var out: [Int] = []
        var e = ((start + 29) / 30) * 30
        while e < end { out.append(e); e += epochS }
        return out
    }

    /// One label per epoch of the grid: the staged span decoded, everything else wake. `end` is the session's.
    static func stageEpochs(epochs: [Int], grav: [GravitySample], hr: [HRSample], rr: [RRInterval],
                            sleepWindow: (from: Int, to: Int)?, end: Int) -> [String] {
        var labels = [String](repeating: "wake", count: epochs.count)
        let inSpan: [Int]
        if let w = sleepWindow {
            inSpan = epochs.indices.filter { SleepStagerTrained.epochInSleepWindow(epochs[$0], w, end: end) }
        } else {
            inSpan = Array(epochs.indices)
        }
        guard let a = inSpan.first, let b = inSpan.last else { return labels }
        let f = features(grav: grav, hr: hr, rr: rr, spanStart: epochs[a], n: b - a + 1)
        for (k, s) in stage(f).enumerated() { labels[a + k] = stages[s] }
        return labels
    }

    // MARK: - Model

    /// One logistic-regression head plus its decoder statistics, as `train.py` writes them.
    struct Head {
        let features: [String]
        let mean: [Double]
        let scale: [Double]
        /// One row per stage (wake, light, deep, rem), one weight per feature.
        let coef: [[Double]]
        let intercept: [Double]
        let prior: [Double]
        let transition: [[Double]]

        /// Per-epoch stage posteriors (softmax of the standardised features' logits).
        func posteriors(_ f: Features) -> [[Double]] {
            let n = f.n
            let cols = features.indices.map { j in
                imputed(f.columns[features[j]] ?? [Double](repeating: .nan, count: n), absent: mean[j])
            }
            var out: [[Double]] = []
            out.reserveCapacity(n)
            for i in 0..<n {
                var logits = intercept
                for j in features.indices {
                    let z = (cols[j][i] - mean[j]) / scale[j]
                    for s in 0..<4 { logits[s] += coef[s][j] * z }
                }
                let m = logits.max()!
                let e = logits.map { Foundation.exp($0 - m) }
                let sum = e.reduce(0, +)
                out.append(e.map { $0 / sum })
            }
            return out
        }

        /// Viterbi over `log max(P, floor) - priorPower * log prior`, started from the prior.
        func decode(_ post: [[Double]]) -> [Int] {
            decode(logPosteriors: post.map { p in p.map { Foundation.log(max($0, probFloor)) } })
        }

        func decode(logPosteriors lp: [[Double]]) -> [Int] {
            let logPrior = prior.map { Foundation.log($0) }
            let logT = transition.map { $0.map { Foundation.log($0) } }
            let em = lp.map { l in (0..<4).map { l[$0] - priorPower * logPrior[$0] } }
            return viterbi(em, logT: logT, logStart: logPrior)
        }
    }

    static let probFloor = 1e-6
    static let priorPower = 0.5
    /// Fraction of the span's epochs that need `hrvMinBeats` beats in their window for the HRV head.
    static let hrvCoverage = 0.5
    /// Weight of the HRV head's log-posterior when both heads run; the base head gets the rest. Equal
    /// weights, not tuned. Against the HRV head alone it moved cross-validated kappa on Wearanize+ 0.554 →
    /// 0.547 and on DREAMT 0.320 → 0.313, and cut the REM over-count 2.1 → 0.1 and 7.9 → 5.9 percentage
    /// points: out of its training cohort the HRV head alone calls REM high.
    static let hrvBlend = 0.5

    static func usesHRV(_ f: Features) -> Bool {
        guard f.n > 0 else { return false }
        let covered = f.beats.reduce(0) { $0 + ($1 >= hrvMinBeats ? 1 : 0) }
        return Double(covered) / Double(f.n) >= hrvCoverage
    }

    /// Stage indices for every epoch of the span.
    static func stage(_ f: Features) -> [Int] {
        guard usesHRV(f) else { return baseHead.decode(baseHead.posteriors(f)) }
        let ph = hrvHead.posteriors(f), pb = baseHead.posteriors(f)
        let lp = zip(ph, pb).map { a, b in
            (0..<4).map { hrvBlend * Foundation.log(max(a[$0], probFloor))
                + (1 - hrvBlend) * Foundation.log(max(b[$0], probFloor)) }
        }
        return hrvHead.decode(logPosteriors: lp)
    }

    /// Most likely state path; a tie keeps the lower state index, in each step and in the final pick.
    static func viterbi(_ em: [[Double]], logT: [[Double]], logStart: [Double]) -> [Int] {
        guard let first = em.first else { return [] }
        let k = first.count
        var v = (0..<k).map { logStart[$0] + first[$0] }
        var back: [[Int]] = [[Int](repeating: 0, count: k)]
        back.reserveCapacity(em.count)
        for t in 1..<em.count {
            var nv = [Double](repeating: 0, count: k), bp = [Int](repeating: 0, count: k)
            for s in 0..<k {
                var best = 0, bestV = v[0] + logT[0][s]
                for p in 1..<k where v[p] + logT[p][s] > bestV { best = p; bestV = v[p] + logT[p][s] }
                nv[s] = bestV + em[t][s]; bp[s] = best
            }
            v = nv; back.append(bp)
        }
        var last = 0
        for s in 1..<k where v[s] > v[last] { last = s }
        var path = [Int](repeating: 0, count: em.count)
        path[em.count - 1] = last
        var t = em.count - 1
        while t > 0 { last = back[t][last]; t -= 1; path[t] = last }
        return path
    }

    /// Missing values take the column's median over the night, so a gap reads as typical for the night rather
    /// than as an extreme. A column missing for the whole night takes `absent`, the head's training mean for
    /// it, so it standardises to 0 and moves no logit.
    ///
    /// A whole-night gap used to take 0, which is neutral only for the z-scored columns. For a percentile
    /// rank (typical value 0.5) or a ratio it is an extreme. A span with gravity but no heart rate yet read as
    /// the lowest, flattest heart rate of the night: hr_pct and the three hrsd ranks at z = -1.74, hr_over_low
    /// at -1.03. On the owner's six banked 5/MG nights with the heart rate removed that staged 32-48 % deep,
    /// against 8-18 % with it present. No training night holds a whole-night gap in a column its head reads,
    /// so the fitted model is unchanged, and so are the PSG figures.
    static func imputed(_ x: [Double], absent: Double) -> [Double] {
        let m = median(x)
        let fill = m.isNaN ? absent : m
        return x.map { $0.isNaN ? fill : $0 }
    }

    // MARK: - Features (a line-for-line port of Tools/SleepTrain/sleeptrain/features.py)

    static let moveMult = 38.0
    static let moveCountInit = 60.0
    static let moveCountCap = 120.0
    static let ctx = [2, 5, 10, 20]
    static let hrsd: [(half: Int, name: String)] = [(150, "5"), (330, "11"), (600, "20")]
    static let hrsdMin = 10
    static let hrCtx = [5, 10, 30]
    static let hrTrend = 10
    static let minutesCap = 720.0
    static let timeDecays = [10, 30, 90]
    static let hrvHalf = 150.0
    static let hrvMinBeats = 20
    static let specMinBeats = 30
    static let specMinSpan = 120.0
    static let dfaMinBeats = 64
    static let hrvCtx = 10
    static let resampleHz = 4.0
    static let nperseg = 256
    static let lfBand = (0.04, 0.15)
    static let hfBand = (0.15, 0.40)
    static let hrvNames = ["meanNN", "sdnn", "lnrmssd", "pnn50", "lnlf", "lnhf", "lnlfhf", "resp_bpm",
                           "hf_peaked", "dfa_a1", "beats_per_min"]

    /// Every feature of the span's `n` epochs by name (NaN = no measurement), and the beat count in each
    /// epoch's 5-minute window.
    struct Features {
        let n: Int
        var columns: [String: [Double]]
        let beats: [Int]
    }

    static func features(grav: [GravitySample], hr: [HRSample], rr: [RRInterval], spanStart: Int, n: Int) -> Features {
        let S = epochS * n
        var cols: [String: [Double]] = [:]

        // Per-second grid (mean of the samples a second carries).
        var gx = [Double](repeating: 0, count: S), gy = gx, gz = gx
        var gc = [Int](repeating: 0, count: S)
        for s in grav {
            let i = s.ts - spanStart
            guard i >= 0 && i < S else { continue }
            gx[i] += s.x; gy[i] += s.y; gz[i] += s.z; gc[i] += 1
        }
        for i in 0..<S {
            if gc[i] > 0 { let c = Double(gc[i]); gx[i] /= c; gy[i] /= c; gz[i] /= c } else { gx[i] = .nan; gy[i] = .nan; gz[i] = .nan }
        }
        var h = [Double](repeating: 0, count: S)
        var hc = [Int](repeating: 0, count: S)
        for s in hr {
            let i = s.ts - spanStart
            guard i >= 0 && i < S, s.bpm > 0 else { continue }
            h[i] += Double(s.bpm); hc[i] += 1
        }
        for i in 0..<S { h[i] = hc[i] > 0 ? h[i] / Double(hc[i]) : .nan }

        // Motion.
        var jerk = [Double](repeating: .nan, count: S)
        if S > 1 {
            for i in 1..<S {
                let dx = gx[i] - gx[i - 1], dy = gy[i] - gy[i - 1], dz = gz[i] - gz[i - 1]
                jerk[i] = (dx * dx + dy * dy + dz * dz).squareRoot()
            }
        }
        var floor = median(jerk)
        if !(floor > 0) { floor = 1e-6 }
        var actMean = [Double](repeating: 0, count: n), actMax = actMean, moveFrac = actMean
        for e in 0..<n {
            var sum = 0.0, mx = -Double.infinity, moves = 0.0
            for i in (epochS * e)..<(epochS * e + epochS) {
                let rel = jerk[i] / floor
                let l = rel.isNaN ? 0.0 : Foundation.log1p(rel)
                sum += l; mx = max(mx, l)
                if !rel.isNaN && rel > moveMult { moves += 1 }
            }
            actMean[e] = sum / Double(epochS); actMax[e] = mx; moveFrac[e] = moves / Double(epochS)
        }
        cols["act_mean"] = actMean; cols["act_max"] = actMax; cols["move_frac"] = moveFrac
        var since = [Double](repeating: 0, count: n), until = since
        var c = moveCountInit
        for i in 0..<n { c = moveFrac[i] > 0 ? 0 : min(c + 1, moveCountCap); since[i] = c }
        c = moveCountInit
        for i in stride(from: n - 1, through: 0, by: -1) { c = moveFrac[i] > 0 ? 0 : min(c + 1, moveCountCap); until[i] = c }
        cols["since_move"] = since.map { Foundation.log1p($0) }
        cols["until_move"] = until.map { Foundation.log1p($0) }
        for w in ctx { cols["act_ctx\(w)"] = centredMean(actMean, w) }
        // No jerk anywhere in the span (no gravity, or none in two consecutive seconds) is no motion
        // measurement: its columns are missing, and so read as typical, not as the stillest night the model
        // ever saw (zero activity and the time since movement at its cap). That is how a night with no motion
        // at all reaches V3, through `SleepStager.hrOnlySessions`.
        if !jerk.contains(where: { !$0.isNaN }) {
            let motion = ["act_mean", "act_max", "move_frac", "since_move", "until_move"] + ctx.map { "act_ctx\($0)" }
            for name in motion { cols[name] = [Double](repeating: .nan, count: n) }
        }

        // Posture: z-angle change between 5 s block means, over the night's median change.
        let blocks = (0..<(S / 5)).map { j -> Double in
            var vals: [Double] = []
            for i in (5 * j)..<(5 * j + 5) {
                vals.append(Foundation.atan2(gz[i], (gx[i] * gx[i] + gy[i] * gy[i]).squareRoot()) * (180.0 / Double.pi))
            }
            return nanMean(vals)
        }
        var dblk = [Double](repeating: 0, count: blocks.count)
        var postureMeasured = false
        if blocks.count > 1 {
            for j in 1..<blocks.count {
                let d = Swift.abs(blocks[j] - blocks[j - 1])
                if !d.isNaN { postureMeasured = true }
                dblk[j] = d.isNaN ? 0 : d
            }
        }
        let perEpoch = epochS / 5
        let dang = (0..<n).map { e in (0..<perEpoch).reduce(0.0) { $0 + dblk[perEpoch * e + $1] } }
        let dmed = median(dang)
        let dangn = dang.map { Foundation.log1p($0 / (dmed > 0 ? dmed : 1e-6)) }
        cols["dangn"] = dangn
        for w in ctx { cols["dangn_ctx\(w)"] = centredMean(dangn, w) }
        // Likewise no two consecutive blocks with gravity is no posture measurement.
        if !postureMeasured {
            for name in ["dangn"] + ctx.map({ "dangn_ctx\($0)" }) { cols[name] = [Double](repeating: .nan, count: n) }
        }

        // Heart rate.
        let ehr = (0..<n).map { e in nanMean(Array(h[(epochS * e)..<(epochS * e + epochS)])) }
        cols["hr_z"] = zscore(ehr); cols["hr_pct"] = pctRank(ehr)
        for (half, name) in hrsd {
            var sd = [Double](repeating: .nan, count: n)
            for e in 0..<n {
                let centre = epochS * e + epochS / 2
                let win = Array(h[max(0, centre - half)..<min(S, centre + half)])
                if win.reduce(0, { $0 + ($1.isNaN ? 0 : 1) }) > hrsdMin { sd[e] = nanStd(win) }
            }
            cols["hrsd\(name)_pct"] = pctRank(sd); cols["hrsd\(name)_z"] = zscore(sd)
        }
        for w in hrCtx { cols["hr_ctx\(w)_z"] = zscore(centredMean(ehr, w)) }
        var trend = [Double](repeating: 0, count: n)
        if n > 1 {
            for e in 1..<n {
                trend[e] = nanMean(Array(ehr[e..<min(n, e + hrTrend)])) - nanMean(Array(ehr[max(0, e - hrTrend)..<e]))
            }
        }
        cols["hr_trend"] = zscore(trend)
        let hsd = nanStd(ehr), p5 = percentile(ehr, 5)
        cols["hr_over_low"] = ehr.map { ($0 - p5) / (hsd > 1e-6 ? hsd : 1e-6) }

        // Time of night.
        cols["clock"] = (0..<n).map { Double($0) / Double(max(1, n - 1)) }
        let minutes = (0..<n).map { min(Double($0) * Double(epochS) / 60.0, minutesCap) }
        cols["minutes"] = minutes
        // A linear head reads `minutes` as a straight line; these decays let it learn the sleep-onset descent
        // (little deep in the first ~20 min, no REM for the first hour) from the data.
        for tau in timeDecays { cols["time_e\(tau)"] = minutes.map { Foundation.exp(-$0 / Double(tau)) } }

        // Heart-rate variability.
        let (bt, bv) = cleanBeats(beatTimes(rr, spanStart: spanStart, n: n))
        let (hrvRaw, count) = epochHRV(t: bt, rr: bv, n: n)
        for (j, name) in hrvNames.enumerated() {
            let r = robust(hrvRaw.map { $0[j] })
            cols["hrv_\(name)_r"] = r
            cols["hrv_\(name)_ctx"] = centredMean(r, hrvCtx)
        }
        return Features(n: n, columns: cols, beats: count)
    }

    /// Beats inside the span as (seconds from span start, interval ms). The c beats one second carries sit at
    /// ts + j / c in their stored order.
    static func beatTimes(_ rr: [RRInterval], spanStart: Int, n: Int) -> ([Double], [Double]) {
        let hi = spanStart + epochS * n
        let kept = StagerInput.sortedByTs(rr, { $0.ts }).filter { $0.ts >= spanStart && $0.ts < hi }
        var t = [Double](), v = [Double]()
        t.reserveCapacity(kept.count); v.reserveCapacity(kept.count)
        var i = 0
        while i < kept.count {
            var j = i
            while j + 1 < kept.count && kept[j + 1].ts == kept[i].ts { j += 1 }
            let c = Double(j - i + 1)
            for k in i...j {
                t.append(Double(kept[i].ts - spanStart) + Double(k - i) / c)
                v.append(Double(kept[k].rrMs))
            }
            i = j + 1
        }
        return (t, v)
    }

    /// Drop impossible intervals, then any more than 20 % from the median of its 11-beat neighbourhood.
    static func cleanBeats(_ beats: ([Double], [Double])) -> ([Double], [Double]) {
        var t: [Double] = [], v: [Double] = []
        for (a, b) in zip(beats.0, beats.1) where b >= 300 && b <= 2000 { t.append(a); v.append(b) }
        if v.count < 5 { return (t, v) }
        var ot: [Double] = [], ov: [Double] = []
        for i in v.indices {
            let m = median(Array(v[max(0, i - 5)..<min(v.count, i + 6)]))
            if Swift.abs(v[i] - m) <= 0.2 * m { ot.append(t[i]); ov.append(v[i]) }
        }
        return (ot, ov)
    }

    /// Raw HRV measures per epoch over the 5-minute window centred on it, and each window's beat count.
    static func epochHRV(t: [Double], rr: [Double], n: Int) -> ([[Double]], [Int]) {
        var out = [[Double]](repeating: [Double](repeating: .nan, count: hrvNames.count), count: n)
        var count = [Int](repeating: 0, count: n)
        for e in 0..<n {
            let c = Double(epochS * e) + Double(epochS) / 2
            let a = lowerBound(t, c - hrvHalf), b = lowerBound(t, c + hrvHalf)
            count[e] = b - a
            if b - a < hrvMinBeats { continue }
            let tt = Array(t[a..<b]), x = Array(rr[a..<b])
            var d2 = 0.0, big = 0.0
            for i in 1..<x.count {
                let d = x[i] - x[i - 1]
                d2 += d * d
                if Swift.abs(d) > 50 { big += 1 }
            }
            let nd = Double(x.count - 1)
            let rmssd = (d2 / nd).squareRoot()
            let (lf, hf, peak, peaked) = spectral(tt, x)
            out[e] = [x.reduce(0, +) / Double(x.count), nanStd(x), Foundation.log(rmssd + 1e-6), big / nd,
                      Foundation.log(lf + 1e-6), Foundation.log(hf + 1e-6),
                      hf > 0 ? Foundation.log(lf / hf + 1e-9) : .nan,
                      peak * 60.0, peaked,
                      x.count >= dfaMinBeats ? dfaAlpha1(x) : .nan,
                      Double(x.count) / (2 * hrvHalf) * 60.0]
        }
        return (out, count)
    }

    /// (LF power, HF power, HF peak frequency, HF peakedness) of the 4 Hz resampled, linearly detrended
    /// tachogram, from a Welch PSD: periodic Hann windows of `nperseg` samples, 50 % overlap, each segment
    /// mean-removed, one-sided density, averaged — scipy.signal.welch's defaults. Only the bins the two
    /// bands read are transformed.
    static func spectral(_ t: [Double], _ rr: [Double]) -> (Double, Double, Double, Double) {
        let nan = Double.nan
        guard rr.count >= specMinBeats, let t0 = t.first, let tN = t.last, tN - t0 >= specMinSpan else {
            return (nan, nan, nan, nan)
        }
        let m = Int(Foundation.ceil((tN - t0) * resampleHz))
        var y = [Double](repeating: 0, count: m), x = y
        var j = 0
        for i in 0..<m {
            let g = t0 + Double(i) / resampleHz
            x[i] = g - t0
            while j + 1 < t.count - 1 && t[j + 1] <= g { j += 1 }
            let slope = (rr[j + 1] - rr[j]) / (t[j + 1] - t[j])
            y[i] = slope * (g - t[j]) + rr[j]
        }
        let xm = x.reduce(0, +) / Double(m), ym = y.reduce(0, +) / Double(m)
        var sxy = 0.0, sxx = 0.0
        for i in 0..<m { sxy += (x[i] - xm) * (y[i] - ym); sxx += (x[i] - xm) * (x[i] - xm) }
        let slope = sxx > 0 ? sxy / sxx : 0
        for i in 0..<m { y[i] -= ym + slope * (x[i] - xm) }

        let step = nperseg / 2
        let nseg = (m - nperseg) / step + 1
        let bins = dftBins, nb = bins.count
        var p = [Double](repeating: 0, count: nb)
        var xs = [Double](repeating: 0, count: nperseg)
        for s in 0..<nseg {
            var mean = 0.0
            for k in 0..<nperseg { mean += y[s * step + k] }
            mean /= Double(nperseg)
            for k in 0..<nperseg { xs[k] = (y[s * step + k] - mean) * hann[k] }
            for i in 0..<nb {
                var re = 0.0, im = 0.0
                let c = dftCos[i], sn = dftSin[i]
                for k in 0..<nperseg { re += xs[k] * c[k]; im += xs[k] * sn[k] }
                p[i] += re * re + im * im
            }
        }
        // Every band bin sits strictly between DC and Nyquist, so each is doubled for the one-sided PSD.
        for i in 0..<nb { p[i] = p[i] * (1.0 / (resampleHz * hannSumSq * Double(nseg))) * 2 }
        func band(_ lo: Double, _ hi: Double) -> Double {
            var s = 0.0, prev: Int?
            for i in 0..<nb where binHz(bins[i]) >= lo && binHz(bins[i]) < hi {
                if let q = prev { s += (binHz(bins[i]) - binHz(bins[q])) * (p[i] + p[q]) / 2 }
                prev = i
            }
            return s
        }
        let lf = band(lfBand.0, lfBand.1), hf = band(hfBand.0, hfBand.1)
        var peak: Int?, total = 0.0
        for i in 0..<nb where binHz(bins[i]) >= hfBand.0 && binHz(bins[i]) < hfBand.1 {
            total += p[i]
            if peak == nil || p[i] > p[peak!] { peak = i }
        }
        return (lf, hf, binHz(bins[peak!]), total > 0 ? p[peak!] / total : nan)
    }

    static func binHz(_ b: Int) -> Double { Double(b) * resampleHz / Double(nperseg) }

    /// The periodic Hann window and its sum of squares (summed in index order).
    static let hann: [Double] = (0..<nperseg).map { 0.5 - 0.5 * Foundation.cos(2 * Double.pi * Double($0) / Double(nperseg)) }
    static let hannSumSq: Double = hann.reduce(0.0) { $0 + $1 * $1 }
    /// The one-sided bins the LF and HF bands read, and their DFT kernels (cos and sin of -2 pi b k / N).
    static let dftBins: [Int] = (0...(nperseg / 2)).filter { binHz($0) >= lfBand.0 && binHz($0) < hfBand.1 }
    static let dftCos: [[Double]] = dftBins.map { b in
        (0..<nperseg).map { Foundation.cos(-2 * Double.pi * Double((b * $0) % nperseg) / Double(nperseg)) }
    }
    static let dftSin: [[Double]] = dftBins.map { b in
        (0..<nperseg).map { Foundation.sin(-2 * Double.pi * Double((b * $0) % nperseg) / Double(nperseg)) }
    }

    /// Detrended fluctuation analysis short-term exponent over box sizes 4-16 beats.
    static func dfaAlpha1(_ rr: [Double]) -> Double {
        let mean = rr.reduce(0, +) / Double(rr.count)
        var x = [Double](repeating: 0, count: rr.count), acc = 0.0
        for i in rr.indices { acc += rr[i] - mean; x[i] = acc }
        var logN: [Double] = [], logF: [Double] = []
        for n in 4...16 {
            let k = x.count / n
            if k < 2 { return .nan }
            let im = Double(n - 1) / 2
            var sii = 0.0
            for i in 0..<n { sii += (Double(i) - im) * (Double(i) - im) }
            var fsum = 0.0
            for s in 0..<k {
                let seg = x[(s * n)..<(s * n + n)]
                let sm = seg.reduce(0, +) / Double(n)
                var sis = 0.0
                for (i, v) in seg.enumerated() { sis += (Double(i) - im) * (v - sm) }
                let slope = sis / sii
                var r2 = 0.0
                for (i, v) in seg.enumerated() { let r = v - sm - slope * (Double(i) - im); r2 += r * r }
                fsum += (r2 / Double(n)).squareRoot()
            }
            let f = fsum / Double(k)
            if f <= 0 { return .nan }
            logN.append(Foundation.log(Double(n))); logF.append(Foundation.log(f))
        }
        let lx = logN.reduce(0, +) / Double(logN.count), ly = logF.reduce(0, +) / Double(logF.count)
        var num = 0.0, den = 0.0
        for i in logN.indices { num += (logN[i] - lx) * (logF[i] - ly); den += (logN[i] - lx) * (logN[i] - lx) }
        return num / den
    }

    // MARK: - Reductions (NaN = missing, as in the reference)

    static func nanMean(_ x: [Double]) -> Double {
        var s = 0.0, c = 0
        for v in x where !v.isNaN { s += v; c += 1 }
        return c > 0 ? s / Double(c) : .nan
    }

    /// Population standard deviation over the present values.
    static func nanStd(_ x: [Double]) -> Double {
        let m = nanMean(x)
        if m.isNaN { return .nan }
        var s = 0.0, c = 0
        for v in x where !v.isNaN { s += (v - m) * (v - m); c += 1 }
        return (s / Double(c)).squareRoot()
    }

    static func median(_ x: [Double]) -> Double {
        let s = x.filter { !$0.isNaN }.sorted()
        if s.isEmpty { return .nan }
        let h = s.count / 2
        return s.count % 2 == 1 ? s[h] : 0.5 * (s[h - 1] + s[h])
    }

    /// Linear-interpolation percentile over the present values.
    static func percentile(_ x: [Double], _ q: Double) -> Double {
        let s = x.filter { !$0.isNaN }.sorted()
        if s.isEmpty { return .nan }
        let pos = q / 100 * Double(s.count - 1)
        let lo = Int(Foundation.floor(pos)), hi = min(lo + 1, s.count - 1)
        return s[lo] + (pos - Double(lo)) * (s[hi] - s[lo])
    }

    static func zscore(_ x: [Double]) -> [Double] {
        let m = nanMean(x), sd = nanStd(x)
        if m.isNaN { return x.map { _ in .nan } }
        let d = sd > 0 ? sd : 1
        return x.map { ($0 - m) / d }
    }

    /// Percentile rank: the average 1-based rank of a value's ties over the count of present values.
    static func pctRank(_ x: [Double]) -> [Double] {
        let s = x.filter { !$0.isNaN }.sorted()
        if s.isEmpty { return x }
        let n = Double(s.count)
        return x.map { v in
            if v.isNaN { return .nan }
            let below = lowerBound(s, v), through = upperBound(s, v)
            return (Double(below) + Double(through - below + 1) / 2) / n
        }
    }

    /// Mean of the present values in [i - w, i + w], clipped to the span; NaN when none is present.
    static func centredMean(_ x: [Double], _ w: Int) -> [Double] {
        let n = x.count
        var cs = [Double](repeating: 0, count: n + 1), cc = [Int](repeating: 0, count: n + 1)
        for i in 0..<n {
            cs[i + 1] = cs[i] + (x[i].isNaN ? 0 : x[i])
            cc[i + 1] = cc[i] + (x[i].isNaN ? 0 : 1)
        }
        return (0..<n).map { i in
            let lo = max(0, i - w), hi = min(n, i + w + 1)
            let c = cc[hi] - cc[lo]
            return c > 0 ? (cs[hi] - cs[lo]) / Double(c) : .nan
        }
    }

    /// Scale to the night's 5th-95th percentile range.
    static func robust(_ x: [Double]) -> [Double] {
        let lo = percentile(x, 5), hi = percentile(x, 95)
        if lo.isNaN { return x.map { _ in .nan } }
        let d = hi > lo ? hi - lo : 1
        return x.map { ($0 - lo) / d }
    }

    static func lowerBound(_ s: [Double], _ v: Double) -> Int {
        var lo = 0, hi = s.count
        while lo < hi { let m = (lo + hi) / 2; if s[m] < v { lo = m + 1 } else { hi = m } }
        return lo
    }

    static func upperBound(_ s: [Double], _ v: Double) -> Int {
        var lo = 0, hi = s.count
        while lo < hi { let m = (lo + hi) / 2; if s[m] <= v { lo = m + 1 } else { hi = m } }
        return lo
    }
}
