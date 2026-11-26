import Foundation
import StrandAnalytics
import WhoopProtocol

// sleeppsg — score NOOP's shipped sleep stager against polysomnography.
//
// USAGE:  sleeppsg --dataset /path/to/sleep-accel-1.0.0 [--section all] [--csv out.csv] [--subjects N]
//         sleeppsg --section port                        (no dataset needed — the port check alone)
//
// The dataset lives outside this repository and is always an argument. Nothing is written to it.

struct Args {
    var dataset: String?
    var section = "all"
    var csv: String?
    var subjects: Int?
    var seed: UInt64 = PortValidation.defaultSeed
}
var a = Args()
var it = CommandLine.arguments.dropFirst().makeIterator()
while let k = it.next() {
    switch k {
    case "--dataset": a.dataset = it.next()
    case "--section": a.section = it.next() ?? a.section
    case "--csv": a.csv = it.next()
    case "--subjects": a.subjects = Int(it.next() ?? "")
    case "--seed": a.seed = UInt64(it.next() ?? "") ?? a.seed
    case "-h", "--help":
        print("""
        usage: sleeppsg --dataset <sleep-accel root> [--section all|port|baseline|strata|rem|variants|priors|restless]
                        [--subjects N] [--csv <path>] [--seed <n>]

          --dataset   PhysioNet sleep-accel v1.0.0, extracted. See README.md for the download step and the
                      attribution its licence requires. Never committed; read-only here.
          --section   which report to print. `port` needs no dataset.
          --subjects  score only the first N subject ids (a fast smoke run; full cohort is the default).
        """)
        exit(0)
    default: FileHandle.standardError.write(Data("unknown argument \(k)\n".utf8)); exit(2)
    }
}

let wantAll = a.section == "all"
func want(_ s: String) -> Bool { wantAll || a.section == s }

// ─────────────────────────────────────────────────────────────────────────────────────────────────────
// 1. PORT VALIDATION
// ─────────────────────────────────────────────────────────────────────────────────────────────────────

if want("port") {
    print("""

    ================================================================================
    1. PORT VALIDATION — does this harness run the SHIPPED recipe?
    ================================================================================
    Every baseline number below comes from `StrandAnalytics.SleepStagerV2.stageSession` directly: the file
    that ships in the app, compiled from `Packages/`, called with no reimplementation in between. The
    VARIANT rows cannot work that way — `SleepStagerV2` holds its constants as `static let`s — so they run
    through `V2Recipe`, a knob-for-knob port in this tool. This section is the check that the port and the
    shipped stager are the same recipe. It runs in `swift test`, and therefore in CI, with no dataset.
    """)
    let r = PortValidation.run(seed: a.seed)
    print("""
    nights            \(r.nights)  (\(r.randomNights) randomised + \(r.degenerateNights) degenerate)
    epoch labels      \(r.matchingEpochs)/\(r.epochs) identical
    verdict           \(r.ok ? "PASS — the port reproduces the shipped stager exactly" : "FAIL")
    """)
    if !r.ok {
        for d in r.divergences.prefix(20) {
            print("  divergence  \(d.night) epoch \(d.epochIndex): shipped=\(d.shipped) port=\(d.port)")
        }
        FileHandle.standardError.write(Data("port validation FAILED — variant numbers are not trustworthy\n".utf8))
        exit(1)
    }
}

if a.section == "port" { exit(0) }

// ─────────────────────────────────────────────────────────────────────────────────────────────────────
// Dataset
// ─────────────────────────────────────────────────────────────────────────────────────────────────────

guard let datasetArg = a.dataset else {
    FileHandle.standardError.write(Data("""
    --dataset is required for every section except `port`.
    See Tools/SleepPSG/README.md for the download step and the attribution the licence requires.

    """.utf8))
    exit(2)
}
guard let root = SleepAccel.resolveRoot(datasetArg) else {
    FileHandle.standardError.write(Data("no `labels/` directory under \(datasetArg) — is that the sleep-accel root?\n".utf8))
    exit(2)
}

var ids = SleepAccel.subjectIDs(root: root)
if let n = a.subjects { ids = Array(ids.prefix(n)) }
// Loaded concurrently — the motion files run to tens of megabytes of text each and the read dominates the
// whole run. Order is restored from `ids` afterwards so the report is identical however the threads finish.
var loaded = [PSGSubject?](repeating: nil, count: ids.count)
loaded.withUnsafeMutableBufferPointer { buf in
    let out = buf
    DispatchQueue.concurrentPerform(iterations: ids.count) { i in
        out[i] = SleepAccel.load(root: root, id: ids[i])
    }
}
let subjects: [PSGSubject] = loaded.compactMap { $0 }
guard !subjects.isEmpty else {
    FileHandle.standardError.write(Data("no scorable subjects under \(root)\n".utf8)); exit(1)
}

let totalScored = subjects.reduce(0) { $0 + $1.scoredEpochs }
print("""

================================================================================
2. DATASET
================================================================================
PhysioNet sleep-accel v1.0.0 — Walch, Huang, Forger & Goldstein, SLEEP 42(12) zsz180 (2019).
Licence: Open Data Commons Attribution v1.0. Root: \(root)

subjects              \(subjects.count)
PSG-scored epochs     \(totalScored)
scored night length   median \(f(median(subjects.map { $0.scoredMinutes }), 6, 1)) min   \
range \(f(subjects.map { $0.scoredMinutes }.min() ?? .nan, 5, 1))–\(f(subjects.map { $0.scoredMinutes }.max() ?? .nan, 5, 1)) min

\(subjects.contains { !$0.rr.isEmpty }
    ? "Beat-to-beat intervals: \(subjects.filter { !$0.rr.isEmpty }.count) of \(subjects.count) subjects carry them (rr/), so the recipe's RSA respiration term is live."
    : "The R-R stream is EMPTY for every subject (this dataset carries no beat-to-beat intervals), so the\nrecipe's RSA respiration term returns nil on every epoch and contributes exactly 0.0 to every emission.\nFive of the recipe's six inputs are live here; the sixth is silent, not wrong.")
""")

// Truth / prediction on the shared 30 s grid, restricted to PSG-scored epochs.
struct Scored {
    let subject: PSGSubject
    let truth: [String]
    let pred: [String]
    /// Full-grid arrays (including unscored epochs) — latency is a property of the hypnogram, not of the
    /// scored subset, so it is measured before masking.
    let fullPred: [String]
    let fullTruth: [String?]
}

func score(_ s: PSGSubject, using stage: (PSGSubject) -> [StageSegment]) -> Scored {
    let segs = stage(s)
    let pred = epochLabels(segs, start: s.start, end: s.end)
    var t: [String] = [], p: [String] = []
    for i in 0..<min(s.truth.count, pred.count) {
        guard let tv = s.truth[i] else { continue }
        t.append(tv); p.append(pred[i])
    }
    return Scored(subject: s, truth: t, pred: p, fullPred: pred, fullTruth: s.truth)
}

/// The SHIPPED stager — `StrandAnalytics.SleepStagerV2`, not the port.
func stageShipped(_ s: PSGSubject) -> [StageSegment] {
    SleepStagerV2.stageSession(start: s.start, end: s.end, grav: s.grav, hr: s.hr, rr: s.rr, resp: [])
}
func stageVariant(_ cfg: RecipeConfig) -> (PSGSubject) -> [StageSegment] {
    { s in V2Recipe.stageSession(start: s.start, end: s.end, grav: s.grav, hr: s.hr,
                                 rr: s.rr, resp: [], cfg: cfg) }
}

let shipped = subjects.map { score($0, using: stageShipped) }

// ─────────────────────────────────────────────────────────────────────────────────────────────────────
// Reporting helpers
// ─────────────────────────────────────────────────────────────────────────────────────────────────────

struct Summary {
    var conf = Confusion()
    var kappa: Double { conf.kappa }
    var accuracy: Double { conf.accuracy }
    var predPct: [String: Double] = [:]
    var truthPct: [String: Double] = [:]
    var latencyPred: [Double] = []
    var latencyTruth: [Double] = []
    var latencyPairsPred: [Double] = []
    var latencyPairsTruth: [Double] = []
    /// Per-subject kappa, excluding any subject whose scored night carries only one class (kappa is
    /// undefined there, and letting a NaN into the mean would quietly void the whole column).
    var subjectKappa: [Double] = []
    var noRemNights = 0
}

func summarise(_ rows: [Scored]) -> Summary {
    var s = Summary()
    var predAcc = [String: Double](), truthAcc = [String: Double]()
    for r in rows {
        var c = Confusion()
        for i in 0..<r.truth.count { c.add(ref: r.truth[i], pred: r.pred[i]) }
        s.conf.merge(c)
        if !c.kappa.isNaN { s.subjectKappa.append(c.kappa) }
        let pp = stagePercentages(r.pred), tp = stagePercentages(r.truth)
        for k in stageOrder { predAcc[k, default: 0] += pp[k]!; truthAcc[k, default: 0] += tp[k]! }
        // Latency: both on the FULL 30 s grid, so both are wall-clock minutes from that night's own
        // sleep onset. The truth column skips unscored epochs when looking for onset and for REM but
        // still counts their slots — collapsing them first would shorten only the truth latency, by
        // however much of the night the technician left unscored.
        let lp = firstRemLatencyMinutes(r.fullPred)
        let lt = firstRemLatencyMinutes(r.fullTruth)
        if let v = lp { s.latencyPred.append(v) } else { s.noRemNights += 1 }
        if let v = lt { s.latencyTruth.append(v) }
        if let x = lp, let y = lt { s.latencyPairsPred.append(x); s.latencyPairsTruth.append(y) }
    }
    let n = Double(rows.count)
    for k in stageOrder { s.predPct[k] = predAcc[k]! / n; s.truthPct[k] = truthAcc[k]! / n }
    return s
}

/// Stage fractions computed over POOLED epochs rather than as a mean of per-night percentages. Both are
/// reported: the pooled number is what a cohort-level "% of night" means, the per-subject mean is what a
/// clinician comparing individuals would use, and they differ whenever night lengths differ.
func pooledPct(_ rows: [Scored], _ pick: (Scored) -> [String]) -> [String: Double] {
    var all: [String] = []
    for r in rows { all.append(contentsOf: pick(r)) }
    return stagePercentages(all)
}

let sh = summarise(shipped)
let pooledPred = pooledPct(shipped) { $0.pred }
let pooledTruth = pooledPct(shipped) { $0.truth }

if want("baseline") {
    print("""

    ================================================================================
    3. SHIPPED SleepStagerV2 vs PSG TRUTH
    ================================================================================
    Four-class agreement over every PSG-scored epoch. `SleepStagerV2` fits no parameters to data — every
    coefficient is fixed a priori — so there is no train/test split to make here: the recipe sees each
    subject exactly once and has never seen any of them. The leave-one-subject-out machinery in section 6
    exists for the fitted comparison models, which do need it.

    epochs scored     \(sh.conf.total)
    accuracy          \(f(sh.accuracy * 100, 6, 2)) %
    Cohen's kappa     \(f(sh.kappa, 6, 3))   (per-subject mean \(f(mean(sh.subjectKappa), 6, 3)) ± \(f(sd(sh.subjectKappa), 5, 3)))

    per stage             precision   recall       F1   support
    """)
    for st in stageOrder {
        let p = sh.conf.prf(st)
        print("      \(st.padding(toLength: 18, withPad: " ", startingAt: 0))\(f(p.precision, 8, 3)) \(f(p.recall, 8, 3)) \(f(p.f1, 8, 3))   \(p.support)")
    }
    print("""

    STAGE FRACTIONS — reported as a first-class result, not an appendix.
    Kappa does not constrain them: PR #348 raised kappa on all three of its benchmarks and was reverted
    48 h later for re-scoring a healthy night from 6 % to 23 % awake.

    stage        predicted %   truth %      bias pp   (pooled over all scored epochs)
    """)
    for st in stageOrder {
        print("      \(st.padding(toLength: 10, withPad: " ", startingAt: 0))\(f(pooledPred[st]!, 10, 2))\(f(pooledTruth[st]!, 10, 2))\(f(pooledPred[st]! - pooledTruth[st]!, 12, 2))")
    }
    print("\n    stage        predicted %   truth %      bias pp   (mean of per-subject percentages)")
    for st in stageOrder {
        print("      \(st.padding(toLength: 10, withPad: " ", startingAt: 0))\(f(sh.predPct[st]!, 10, 2))\(f(sh.truthPct[st]!, 10, 2))\(f(sh.predPct[st]! - sh.truthPct[st]!, 12, 2))")
    }
    print("""

    FIRST-REM LATENCY — minutes from staged sleep onset to the first REM epoch.
    nights with no REM in the prediction: \(sh.noRemNights) of \(shipped.count)

                        predicted     truth
      median          \(f(median(sh.latencyPred), 10, 1))\(f(median(sh.latencyTruth), 10, 1))  min
      mean            \(f(mean(sh.latencyPred), 10, 1))\(f(mean(sh.latencyTruth), 10, 1))  min
      MAE (paired)    \(f(mae(zip(sh.latencyPairsPred, sh.latencyPairsTruth).map { $0 - $1 }), 10, 1))            min  (n = \(sh.latencyPairsPred.count))
    """)

    // A harness that replaces a deleted one has to say whether it is the same instrument. These are the
    // figures the previous harness reported on this dataset. They are printed as a self-check, NOT as a
    // target: nothing in this tool is tuned to hit them, and where they disagree the disagreement is the
    // finding. See `Variants.preNine30Guard` for what explains the prediction-side gap.
    let ref: [(String, Double, Double, Int)] = [
        ("subjects", Double(subjects.count), 31, 0),
        ("PSG-scored epochs", Double(sh.conf.total), 26773, 0),
        ("kappa (4-class)", sh.kappa, 0.349, 3),
        ("REM F1", sh.conf.prf("rem").f1, 0.515, 3),
        ("REM % of night", sh.predPct["rem"]!, 20.8, 2),
        ("deep % predicted", sh.predPct["deep"]!, 19.25, 2),
        ("deep % truth", sh.truthPct["deep"]!, 14.76, 2),
        ("first-REM predicted, min", median(sh.latencyPred), 142.0, 1),
        ("first-REM truth, min", median(sh.latencyTruth), 88.5, 1),
    ]
    print("""

    SELF-CHECK against the previous harness's reported figures
    Printed to expose disagreement, not to be matched. Nothing here is tuned to these numbers. Stage
    fractions use the per-subject-mean convention, which is the one those figures were reported on.

    quantity                        measured   previously      delta
    """)
    for (name, got, want, dp) in ref {
        print("      \(name.padding(toLength: 28, withPad: " ", startingAt: 0))\(f(got, 9, dp))\(f(want, 13, dp))\(f(got - want, 11, dp))")
    }
}

// ─────────────────────────────────────────────────────────────────────────────────────────────────────
// Night-length stratification
// ─────────────────────────────────────────────────────────────────────────────────────────────────────

if want("strata") {
    print("""

    ================================================================================
    4. STRATIFIED BY NIGHT LENGTH
    ================================================================================
    Pooling hides a coupling. On one wearer's own nights, `SleepStagerV2` emits more REM as a fraction of
    sleep the longer the night runs — corr(total sleep, REM %) = +0.579 — traced to the REM-latency guard
    being a fixed 60-minute penalty, which therefore covers a third of a short night and a tenth of a long
    one. Whether that reproduces against PSG is a question a pooled table cannot be asked.

    Subjects split into terciles by SCORED night length.
    """)
    let sortedRows = shipped.sorted { $0.subject.scoredMinutes < $1.subject.scoredMinutes }
    let third = max(1, sortedRows.count / 3)
    let strata: [(String, [Scored])] = [
        ("short", Array(sortedRows.prefix(third))),
        ("mid", Array(sortedRows.dropFirst(third).dropLast(sortedRows.count - 2 * third))),
        ("long", Array(sortedRows.suffix(sortedRows.count - 2 * third))),
    ]
    print("    stratum   n   night min      kappa   REM% pred  REM% truth   deep% pred deep% truth  wake% pred wake% truth")
    for (name, rows) in strata where !rows.isEmpty {
        let p = pooledPct(rows) { $0.pred }, t = pooledPct(rows) { $0.truth }
        var c = Confusion()
        for r in rows { for i in 0..<r.truth.count { c.add(ref: r.truth[i], pred: r.pred[i]) } }
        let mins = rows.map { $0.subject.scoredMinutes }
        print("    \(name.padding(toLength: 9, withPad: " ", startingAt: 0))\(rows.count)  \(f(median(mins), 8, 1))  \(f(c.kappa, 9, 3))  \(f(p["rem"]!, 9, 2)) \(f(t["rem"]!, 10, 2))  \(f(p["deep"]!, 10, 2)) \(f(t["deep"]!, 10, 2))  \(f(p["wake"]!, 10, 2)) \(f(t["wake"]!, 10, 2))")
    }
    // The coupling itself, per subject: REM as a percentage of SLEEP (not of the window), against the
    // length of the scored night.
    func remPctOfSleep(_ labels: [String]) -> Double? {
        let sleep = labels.filter { $0 != "wake" }.count
        guard sleep > 0 else { return nil }
        return Double(labels.filter { $0 == "rem" }.count) / Double(sleep) * 100
    }
    var lens: [Double] = [], remPred: [Double] = [], remTruth: [Double] = []
    for r in shipped {
        guard let rp = remPctOfSleep(r.pred), let rt = remPctOfSleep(r.truth) else { continue }
        lens.append(r.subject.scoredMinutes); remPred.append(rp); remTruth.append(rt)
    }
    let cp = pearson(lens, remPred), ct = pearson(lens, remTruth)
    print("""

    corr(scored night length, REM % of SLEEP), n = \(cp.n)
      predicted   Pearson \(f(cp.r, 7, 3))   Spearman \(f(spearman(lens, remPred), 7, 3))
      PSG truth   Pearson \(f(ct.r, 7, 3))   Spearman \(f(spearman(lens, remTruth), 7, 3))
    A coupling the truth also carries is physiology; one only the prediction carries is an artefact.
    """)
}

// ─────────────────────────────────────────────────────────────────────────────────────────────────────
// The REM question
// ─────────────────────────────────────────────────────────────────────────────────────────────────────

if want("rem") {
    print("""

    ================================================================================
    5. IS REM DETECTION PHYSIOLOGY, OR IS IT THE CLOCK?
    ================================================================================
    Three models fit on the same epochs, leave-one-SUBJECT-out, scored only on the held-out subject.
    Clock features are the time-of-night fraction and its square; physiology features are the per-night
    z-scored heart rate, HR-variability and movement plus the HR-flatness percentile — the same normalised
    quantities the recipe's own emissions are built from. Decision threshold tuned on the training folds.
    """)
    var rows: [AblationRow] = []
    for s in subjects {
        let (feats, _) = V2Recipe.stageEpochsDetailed(start: s.start, end: s.end, grav: s.grav,
                                                      hr: s.hr, rr: s.rr, resp: [])
        // Per-night normalisation, matching `stageEpochs`.
        func zfun(_ vals: [Double?]) -> (Double?) -> Double {
            let present = vals.compactMap { $0 }
            if present.isEmpty { return { _ in 0.0 } }
            let m = present.reduce(0, +) / Double(present.count)
            let sd0 = (present.reduce(0.0) { $0 + ($1 - m) * ($1 - m) } / Double(present.count)).squareRoot()
            let sdv = sd0 == 0 ? 1.0 : sd0
            return { v in v == nil ? 0.0 : (v! - m) / sdv }
        }
        let zhr = zfun(feats.map { $0.hr }), zhv = zfun(feats.map { $0.hrVar })
        let zmv = zfun(feats.map { Optional($0.moveFrac) })
        let fsorted = feats.compactMap { $0.hrFlat11 }.sorted()
        func fpct(_ v: Double?) -> Double {
            guard let v = v, !fsorted.isEmpty else { return 0.5 }
            var lo = 0, hi = fsorted.count
            while lo < hi { let mid = (lo + hi) / 2; if fsorted[mid] <= v { lo = mid + 1 } else { hi = mid } }
            return Double(lo) / Double(fsorted.count)
        }
        for e in feats {
            let idx = (e.start - s.start) / 30
            guard idx >= 0, idx < s.truth.count, let tv = s.truth[idx] else { continue }
            rows.append(AblationRow(
                subject: s.id, isRem: tv == "rem",
                clock: [e.clock, e.clock * e.clock],
                physiology: [zhr(e.hr), zhv(e.hrVar), zmv(e.moveFrac), fpct(e.hrFlat11)]))
        }
    }
    print("    epochs in the comparison: \(rows.count)   REM prevalence \(f(Double(rows.filter { $0.isRem }.count) / Double(max(1, rows.count)) * 100, 5, 1)) %\n")
    let res = Ablation.run(rows)
    print("    model               pooled F1   pooled P   pooled R   mean per-subject F1")
    for r in res {
        print("      \(r.model.rawValue.padding(toLength: 18, withPad: " ", startingAt: 0))\(f(r.pooledF1, 8, 3))  \(f(r.pooledPrecision, 9, 3))  \(f(r.pooledRecall, 9, 3))   \(f(r.meanSubjectF1, 12, 3))")
    }
    if let clock = res.first(where: { $0.model == .clock }),
       let phys = res.first(where: { $0.model == .physiology }),
       let both = res.first(where: { $0.model == .both }) {
        let subs = clock.subjectF1.keys.sorted()
        let dPhys = subs.compactMap { s -> Double? in
            guard let c = clock.subjectF1[s], let p = phys.subjectF1[s] else { return nil }
            return p - c
        }
        let dBoth = subs.compactMap { s -> Double? in
            guard let c = clock.subjectF1[s], let b = both.subjectF1[s] else { return nil }
            return b - c
        }
        print("""

            what physiology adds over the clock, per subject
              physiology-only − clock-only   mean \(f(mean(dPhys), 7, 3))   positive in \(dPhys.filter { $0 > 0 }.count)/\(dPhys.count) subjects
              both − clock-only              mean \(f(mean(dBoth), 7, 3))   positive in \(dBoth.filter { $0 > 0 }.count)/\(dBoth.count) subjects
              pooled: physiology-only − clock-only \(f(phys.pooledF1 - clock.pooledF1, 7, 3)),  both − clock-only \(f(both.pooledF1 - clock.pooledF1, 7, 3))

            For reference, the SHIPPED recipe's own REM F1 on these epochs is \(f(sh.conf.prf("rem").f1, 6, 3)) — it fits
            nothing, so it is not comparable to a fitted model's held-out score and is printed only for scale.
        """)
    }
}

// ─────────────────────────────────────────────────────────────────────────────────────────────────────
// Variants
// ─────────────────────────────────────────────────────────────────────────────────────────────────────

if want("variants") {
    print("""

    ================================================================================
    6. RECIPE VARIANTS AGAINST PSG
    ================================================================================
    Every row is the shipped recipe with ONE named change. Deltas are against the incumbent row.
    `wake bias` and `deep bias` are predicted minus truth in percentage points — the #437 guard, which
    kappa does not carry.
    """)
    var csvLines = [(["variant", "epochs", "kappa", "accuracy"]
        + stageOrder.flatMap { ["\($0)_precision", "\($0)_recall", "\($0)_f1", "\($0)_pct", "\($0)_bias_pp"] }
        + ["median_rem_latency_min", "rem_latency_mae_min"]).joined(separator: ",")]
    var base: (kappa: Double, remF1: Double, wakeSens: Double)?
    // Wake SENSITIVITY is in the table beside kappa because it is the quantity #987 was landed on against
    // the strap's band state (16.0 % → 17.6 %). Printing it here is what makes that claim checkable against
    // truth rather than merely restated.
    print("    variant                          kappa     Δκ   REM F1  wakeSens   wake%  bias   deep%  bias    REM%  bias   latMAE")
    for v in Variants.all {
        let rows = v.name.hasPrefix("incumbent")
            ? shipped
            : subjects.map { score($0, using: stageVariant(v.config)) }
        let s = summarise(rows)
        let p = pooledPct(rows) { $0.pred }, t = pooledPct(rows) { $0.truth }
        let latMae = mae(zip(s.latencyPairsPred, s.latencyPairsTruth).map { $0 - $1 })
        let wakeSens = s.conf.prf("wake").recall * 100
        if base == nil { base = (s.kappa, s.conf.prf("rem").f1, wakeSens) }
        let b = base!
        print("    \(v.name.padding(toLength: 32, withPad: " ", startingAt: 0))\(f(s.kappa, 6, 3)) \(f(s.kappa - b.kappa, 6, 3))   \(f(s.conf.prf("rem").f1, 6, 3))  \(f(wakeSens, 6, 2))\(f(wakeSens - b.wakeSens, 6, 2))  \(f(p["wake"]!, 6, 2))\(f(p["wake"]! - t["wake"]!, 6, 2))  \(f(p["deep"]!, 6, 2))\(f(p["deep"]! - t["deep"]!, 6, 2))  \(f(p["rem"]!, 6, 2))\(f(p["rem"]! - t["rem"]!, 6, 2))  \(f(latMae, 6, 1))")
        var row = [v.name, "\(s.conf.total)", "\(s.kappa)", "\(s.accuracy)"]
        for st in stageOrder {
            let m = s.conf.prf(st)
            row += ["\(m.precision)", "\(m.recall)", "\(m.f1)", "\(p[st]!)", "\(p[st]! - t[st]!)"]
        }
        row += ["\(median(s.latencyPred))", "\(latMae)"]
        csvLines.append(row.joined(separator: ","))
    }
    print("""

    A component is an improvement here only if it raises kappa AND does not blow out a stage fraction.
    That conjunction is the lesson of #348 → #437: kappa alone certified a build that mis-called a
    healthy night's wake fraction by 17 percentage points.
    """)
    if let path = a.csv {
        try? csvLines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        print("    per-variant CSV written to \(path)")
    }
}

if want("priors") {
    print("""

    ================================================================================
    7. BASE PRIORS, SUBJECT BY SUBJECT
    ================================================================================
    The pooled table above can be carried by a few long nights. Here every subject counts once: their own
    kappa, and how far each stage's share of THEIR night is from their own PSG. The deep prior moved 0.18 →
    0.15 on this section's evidence; the "before" row is that change undone, and #348-A adds the awake half
    the recipe does not take. `better` counts subjects whose value improved against the incumbent (kappa up,
    |bias| down); a tie counts as neither.
    """)
    func perSubject(_ rows: [Scored]) -> [(kappa: Double, bias: [String: Double])] {
        rows.map { r in
            let bias = stageBias(ref: r.truth, pred: r.pred)
            return (confusion(ref: r.truth, pred: r.pred).kappa, bias)
        }
    }
    let base = perSubject(shipped)
    // `max wake +pp` is the largest rise in one subject's wake share against the incumbent: the #437 failure
    // was a single healthy night going from 6 % to 23 % awake, which a mean over 31 subjects can hide.
    print("    variant                     mean κ  better κ   mean|bias| wake  deep   REM  light   better |bias| wake deep  REM light   max wake +pp")
    for v in [Variants.incumbent, Variants.deepPriorBefore, Variants.p348Priors, Variants.restlessWake59] {
        let rows = v.name.hasPrefix("incumbent") ? shipped : subjects.map { score($0, using: stageVariant(v.config)) }
        let ps = perSubject(rows)
        let n = ps.count
        let kBetter = zip(ps, base).filter { $0.0.kappa > $0.1.kappa }.count
        func meanAbs(_ st: String) -> Double { mean(ps.map { abs($0.bias[st] ?? 0) }) }
        func better(_ st: String) -> Int { zip(ps, base).filter { abs($0.0.bias[st] ?? 0) < abs($0.1.bias[st] ?? 0) }.count }
        print("    \(v.name.padding(toLength: 26, withPad: " ", startingAt: 0))\(f(mean(ps.map { $0.kappa }), 7, 3))   \(kBetter)/\(n)     "
              + "\(f(meanAbs("wake"), 5, 2)) \(f(meanAbs("deep"), 5, 2)) \(f(meanAbs("rem"), 5, 2)) \(f(meanAbs("light"), 5, 2))      "
              + "\(better("wake"))/\(n) \(better("deep"))/\(n) \(better("rem"))/\(n) \(better("light"))/\(n)   "
              + "\(f(zip(ps, base).map { ($0.0.bias["wake"] ?? 0) - ($0.1.bias["wake"] ?? 0) }.max() ?? 0, 6, 2))")
    }
}

if want("restless") {
    print("""

    ================================================================================
    8. RESTLESS WAKE (#59) AND TWO DEFENCES FOR CALM SLEEPERS
    ================================================================================
    #59 as filed z-scores the small-movement density within each night, so a calm sleeper's mildest stretch
    reads as restless. `sustained` counts only movement that lasts longer than a REM twitch (3 s or less,
    Reiter 2020). `others` scales the density against the OTHER 30 subjects instead of the night itself
    (leave-one-subject-out), standing in for a wearer's own earlier nights. `over+5` counts subjects whose
    predicted wake share exceeds their PSG wake share by more than 5 points.
    """)
    struct Moments { var n = 0.0, sum = 0.0, sq = 0.0 }
    func moments(_ cfg: RecipeConfig) -> [Moments] {
        subjects.map { sub in
            let (ep, _) = V2Recipe.stageEpochsDetailed(start: sub.start, end: sub.end, grav: sub.grav, hr: sub.hr,
                                                       rr: sub.rr, resp: [], cfg: cfg)
            var m = Moments()
            for d in V2Recipe.restlessDensity(ep, cfg) { m.n += 1; m.sum += d; m.sq += d * d }
            return m
        }
    }
    func rowsLeavingOneOut(_ cfg: RecipeConfig) -> [Scored] {
        let ms = moments(cfg)
        let tot = ms.reduce(Moments()) { Moments(n: $0.n + $1.n, sum: $0.sum + $1.sum, sq: $0.sq + $1.sq) }
        return subjects.indices.map { i in
            let n = tot.n - ms[i].n, sm = tot.sum - ms[i].sum, sq = tot.sq - ms[i].sq
            let mu = sm / n
            var c = cfg
            c.smallMoveReference = (mu, max(0, sq / n - mu * mu).squareRoot())
            return score(subjects[i], using: stageVariant(c))
        }
    }
    var filed = Variants.restlessWake59.config
    var sustained = filed; sustained.smallMoveMinRun = 5
    // The pooled reference itself, so two datasets (two devices) can be compared: a fixed reference in the
    // app is only defensible if the density means roughly the same thing on different wrists.
    for (label, cfg) in [("every jerk", filed), ("sustained", sustained)] {
        let t = moments(cfg).reduce(Moments()) { Moments(n: $0.n + $1.n, sum: $0.sum + $1.sum, sq: $0.sq + $1.sq) }
        let mu = t.sum / t.n
        print("    pooled density (\(label)): mean \(f(mu, 7, 4))  sd \(f(max(0, t.sq / t.n - mu * mu).squareRoot(), 7, 4))  over \(Int(t.n)) epochs")
    }
    let variants: [(String, [Scored])] = [
        ("incumbent (shipped)", shipped),
        ("#59 as filed", subjects.map { score($0, using: stageVariant(filed)) }),
        ("#59 sustained", subjects.map { score($0, using: stageVariant(sustained)) }),
        ("#59 others", rowsLeavingOneOut(filed)),
        ("#59 sustained + others", rowsLeavingOneOut(sustained)),
        ("  ... against REM only", rowsLeavingOneOut({ var c = sustained; c.smallMoveAwakeWeight = 0; return c }())),
        ("  ... wake only if HR up", rowsLeavingOneOut({ var c = sustained; c.smallMoveAwakeNeedsRaisedHR = true; return c }())),
        ("#59 sustained, REM only", subjects.map { score($0, using: stageVariant({ var c = sustained; c.smallMoveAwakeWeight = 0; return c }())) }),
        ("#59 sustained, HR-gated", subjects.map { score($0, using: stageVariant({ var c = sustained; c.smallMoveAwakeNeedsRaisedHR = true; return c }())) }),
        ("ayiskakov V3 (trained)", subjects.map { score($0, using: { s in
            SleepStagerTrained.stageSession(start: s.start, end: s.end, grav: s.grav, hr: s.hr, rr: s.rr, resp: []) }) }),
    ]
    filed.smallMoveMinRun = 1
    print("    variant                    kappa  REM F1 wakeSens  wake% bias   REM% bias  mean κ  over+5  max wake +pp (truth/before/after)")
    for (name, rows) in variants {
        let sm = summarise(rows)
        let p = pooledPct(rows) { $0.pred }, t = pooledPct(rows) { $0.truth }
        let perK = rows.map { confusion(ref: $0.truth, pred: $0.pred).kappa }
        let wakeOf: (Scored) -> (truth: Double, pred: Double) = {
            (stagePercentages($0.truth)["wake"] ?? 0, stagePercentages($0.pred)["wake"] ?? 0)
        }
        let over = rows.filter { let w = wakeOf($0); return w.pred - w.truth > 5 }.count
        let rises = zip(rows, shipped).map { (wakeOf($0.0).pred - wakeOf($0.1).pred, wakeOf($0.0).truth, wakeOf($0.1).pred, wakeOf($0.0).pred) }
        let worst = rises.max { $0.0 < $1.0 }!
        print("    \(name.padding(toLength: 25, withPad: " ", startingAt: 0))\(f(sm.kappa, 6, 3)) \(f(sm.conf.prf("rem").f1, 6, 3))  \(f(sm.conf.prf("wake").recall * 100, 6, 1))  "
              + "\(f(p["wake"]!, 5, 1))\(f(p["wake"]! - t["wake"]!, 5, 1))  \(f(p["rem"]!, 5, 1))\(f(p["rem"]! - t["rem"]!, 5, 1))  "
              + "\(f(mean(perK), 6, 3))   \(over)/\(rows.count)   \(f(worst.0, 5, 1)) (\(f(worst.1, 4, 1))/\(f(worst.2, 4, 1))/\(f(worst.3, 4, 1)))")
    }
    // The guard agreed for a Lab default (docs/fork/decisions.md, 2026-11-26), each part against the incumbent:
    // calm sleepers (under 6 % PSG wake) at most 1 point worse on wake, at most 1 in 30 subjects over-called by
    // more than 5 points of wake, the per-subject REM error at most 2 points worse, and on a set with heart rate
    // no night at 0 % REM where the lab measured over 10 %.
    print("""

        guard vs incumbent      calm wake err (Δ)   over+5 (limit)   REM err (Δ)   REM collapse   verdict
    """)
    func pct(_ r: Scored, _ st: String, truth: Bool) -> Double { stagePercentages(truth ? r.truth : r.pred)[st] ?? 0 }
    let calm = shipped.indices.filter { pct(shipped[$0], "wake", truth: true) < 6 }
    let hasHR = subjects.contains { !$0.hr.isEmpty }
    func calmWakeErr(_ rows: [Scored]) -> Double {
        calm.isEmpty ? 0 : mean(calm.map { abs(pct(rows[$0], "wake", truth: false) - pct(rows[$0], "wake", truth: true)) })
    }
    func remErr(_ rows: [Scored]) -> Double {
        mean(rows.map { abs(pct($0, "rem", truth: false) - pct($0, "rem", truth: true)) })
    }
    let baseCalm = calmWakeErr(shipped), baseRem = remErr(shipped)
    let overLimit = max(1, subjects.count / 30)
    for (name, rows) in variants where !name.hasPrefix("incumbent") {
        let c = calmWakeErr(rows), r = remErr(rows)
        let over = rows.filter { pct($0, "wake", truth: false) - pct($0, "wake", truth: true) > 5 }.count
        let collapse = hasHR ? rows.filter { pct($0, "rem", truth: false) == 0 && pct($0, "rem", truth: true) > 10 }.count : 0
        let pass = c - baseCalm <= 1 && over <= overLimit && r - baseRem <= 2 && collapse == 0
        print("    \(name.padding(toLength: 24, withPad: " ", startingAt: 0))  \(f(c, 5, 1)) (\(f(c - baseCalm, 5, 1)))      "
              + "\(over)/\(rows.count) (\(overLimit))       \(f(r, 5, 1)) (\(f(r - baseRem, 5, 1)))    \(hasHR ? "\(collapse)" : "n/a")"
              + "            \(pass ? "PASS" : "FAIL")")
    }
    print("    calm sleepers: \(calm.count) of \(subjects.count); REM collapse is only judged where heart rate exists.")
    // Per subject and variant, so a reader can look at the calm sleepers rather than at a pooled row.
    if let path = a.csv {
        var lines = ["variant,subject,truth_wake_pct,pred_wake_pct,truth_rem_pct,pred_rem_pct,kappa"]
        for (name, rows) in variants {
            for r in rows {
                let t = stagePercentages(r.truth), p = stagePercentages(r.pred)
                lines.append("\"\(name)\",\(r.subject.id),\(t["wake"] ?? 0),\(p["wake"] ?? 0),\(t["rem"] ?? 0),\(p["rem"] ?? 0),"
                             + "\(confusion(ref: r.truth, pred: r.pred).kappa)")
            }
        }
        try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        print("    per-subject CSV written to \(path)")
    }
}

print("")
