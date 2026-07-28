import Foundation
import StrandAnalytics
import WhoopProtocol

// sleepbench — replay the sleep stagers over real recorded nights and score them against every
// independent reference the database carries.
//
// USAGE:  sleepbench --db /path/to/whoop.sqlite [--device my-whoop-noop] [--pad 3600] [--csv out.csv]
//
// The database is never written to and never lives in this repository. Pass a COPY; never point this at
// a device's live database.

struct Args {
    var db = ""
    /// The `sleepSession.deviceId` whose nights are scored.
    var device = "my-whoop-noop"
    /// The `deviceId` the raw streams are stored under. These genuinely differ in a real database — the
    /// session rows carry the app's own device identity while the decoded streams carry the strap's — so
    /// the two are separate arguments rather than one assumed-shared value.
    var streamDevice = "my-whoop"
    var pad = 3600
    var csv: String?
}
var a = Args()
var it = CommandLine.arguments.dropFirst().makeIterator()
while let k = it.next() {
    switch k {
    case "--db": a.db = it.next() ?? ""
    case "--device": a.device = it.next() ?? a.device
    case "--stream-device": a.streamDevice = it.next() ?? a.streamDevice
    case "--pad": a.pad = Int(it.next() ?? "") ?? a.pad
    case "--csv": a.csv = it.next()
    default: FileHandle.standardError.write(Data("unknown argument \(k)\n".utf8)); exit(2)
    }
}
guard !a.db.isEmpty else {
    print("usage: sleepbench --db <sqlite> [--device <id>] [--pad <s>] [--csv <path>]")
    exit(2)
}

let db = try ReadOnlyDB(path: a.db)
let rows = try db.sessions(device: a.device)
guard !rows.isEmpty else { print("no sessions for device \(a.device)"); exit(1) }
// Which `userEdited` rows carry a HUMAN-AUTHORED hypnogram rather than machine stages re-derived over a
// human-corrected window. Only the former can serve as a stage-level reference.
let stageLocked = try db.stageLockedStarts(device: a.device)
let editedCount = rows.filter { $0.userEdited }.count
print("""

================================================================================
0. GROUND-TRUTH PROVENANCE
================================================================================
sessions \(rows.count)   userEdited \(editedCount)   of which stage-locked (human-authored stages) \(rows.filter { $0.userEdited && stageLocked.contains($0.startTs) }.count)

A `userEdited` row alone does NOT prove human stage labels: the local editor corrects bed/wake BOUNDS and
then re-derives the hypnogram from raw, so its stages are machine output over a human-chosen window. Only
a row carrying a `stagelock` cursor had its stages authored directly (the cloud `edit_sleep_stages` path).
Rows without the lock are reported below but are not treated as a stage-level reference.
""")

func nightLabel(_ ts: Int) -> String {
    // Name each night by its local-ish calendar date. -7 h keeps a post-midnight start on the prior
    // night, matching how the app groups a night to a day. Display only; nothing scores on it.
    let d = Date(timeIntervalSince1970: Double(ts - 7 * 3600))
    let fm = DateFormatter()
    fm.dateFormat = "yyyy-MM-dd"; fm.timeZone = TimeZone(identifier: "UTC")
    return fm.string(from: d)
}

/// A mirror of PR #738's `SleepStager.applyBandStateWakeVeto`, which is `internal` and so unreachable
/// from this executable. Logic is transcribed line-for-line from that PR: only band state 2 ("asleep")
/// vetoes, only INTERIOR wake (between the first and last sleep epoch) is touched, and wake only ever
/// becomes sleep. `SleepStagerTests` pins the real implementation; this mirror exists purely so the
/// veto's effect can be scored on the isolated staging path as well as end-to-end.
func bandVetoMirror(_ labels: [String], bandEpochs: [Int]) -> [String] {
    guard !bandEpochs.isEmpty, labels.count == bandEpochs.count else { return labels }
    guard let onset = labels.firstIndex(where: { $0 != "wake" }),
          let final = labels.lastIndex(where: { $0 != "wake" }), onset <= final else { return labels }
    var out = labels
    for i in onset...final where out[i] == "wake" && bandEpochs[i] == SleepStager.bandStateAsleep {
        out[i] = "light"
    }
    return out
}

// MARK: - Replay every night

struct Night {
    let row: SessionRow
    let night: String
    let truth: [String]?          // the wearer's manual restage, when this night was edited
    let v1: [String]
    let v2: [String]
    let v1Veto: [String]
    let v2Veto: [String]
    let band: [Int]               // per-epoch band sleep_state, [] when the strap banked none
    let meanHR: Double
    let machineWakeMin: Double?   // wake implied by the STALE pre-edit efficiency column
    let hasSteps: Bool
}

var nights: [Night] = []
FileHandle.standardError.write(Data("replaying \(rows.count) sessions…\n".utf8))

for r in rows {
    let st = try db.streams(device: a.streamDevice, from: r.startTs - a.pad, to: r.endTs + a.pad)
    // Both stagers take the same window and the same streams; only the recipe differs.
    let v1 = SleepStager.stageSession(start: r.startTs, end: r.endTs, grav: st.grav,
                                      hr: st.hr, rr: st.rr, resp: st.resp)
    let v2 = SleepStagerV2.stageSession(start: r.startTs, end: r.endTs, grav: st.grav,
                                        hr: st.hr, rr: st.rr, resp: st.resp)
    let n = epochCount(start: r.startTs, end: r.endTs)
    let bandEpochs = SleepStager.sessionEpochSleepState(start: r.startTs, end: r.endTs,
                                                        sleepState: st.band)
    let l1 = epochLabels(v1, start: r.startTs, end: r.endTs)
    let l2 = epochLabels(v2, start: r.startTs, end: r.endTs)
    let truth = r.userEdited ? epochLabels(r.stages, start: r.startTs, end: r.endTs) : nil
    let hrS = try db.hrStats(device: a.streamDevice, from: r.startTs, to: r.endTs)
    // The stale `efficiency` column is the machine's own pre-edit verdict on an edited night.
    let machineWake = r.userEdited ? r.efficiency.map { (1 - $0) * r.durMin } : nil

    nights.append(Night(
        row: r, night: nightLabel(r.startTs), truth: truth,
        v1: l1, v2: l2,
        v1Veto: bandVetoMirror(l1, bandEpochs: bandEpochs),
        v2Veto: bandVetoMirror(l2, bandEpochs: bandEpochs),
        band: bandEpochs.count == n ? bandEpochs : [],
        meanHR: hrS?.mean ?? .nan,
        machineWakeMin: machineWake,
        hasSteps: !st.steps.isEmpty))
    FileHandle.standardError.write(Data(".".utf8))
}
FileHandle.standardError.write(Data("\n".utf8))

// MARK: - A. Which stager actually produced the stored hypnograms?

print("""

================================================================================
A. WHICH STAGER PRODUCED THE STORED NIGHTS?
================================================================================
On an unedited night the stored `stagesJSON` is whatever the live stager emitted. Replaying V1 and V2
over the identical window + streams and comparing epoch-for-epoch identifies the live recipe. On an
edited night `stagesJSON` is the wearer's restage, so those are excluded here.
""")
var v1Match = 0, v2Match = 0, neither = 0
/// An edited night whose stored hypnogram is BYTE-IDENTICAL to a fresh V2 replay cannot serve as an
/// independent reference for V2, whatever produced it: scoring V2 against it would be self-comparison.
/// This says nothing about HOW the row came to match — the harness reports the fact and excludes the
/// night, and deliberately does not assert a mechanism it has not established.
var indistinguishableFromV2: Set<String> = []
print("night        edited  epochs  V1 agree  V2 agree  verdict")
for nt in nights {
    let stored = epochLabels(nt.row.stages, start: nt.row.startTs, end: nt.row.endTs)
    let a1 = zip(stored, nt.v1).filter { $0 == $1 }.count
    let a2 = zip(stored, nt.v2).filter { $0 == $1 }.count
    let p1 = Double(a1) / Double(stored.count) * 100, p2 = Double(a2) / Double(stored.count) * 100
    let verdict = p2 >= 99.9 ? "V2 exact" : (p1 >= 99.9 ? "V1 exact" : (p2 > p1 ? "V2 closer" : "V1 closer"))
    if !nt.row.userEdited {
        if p2 >= 99.9 { v2Match += 1 } else if p1 >= 99.9 { v1Match += 1 } else { neither += 1 }
    } else if p2 >= 99.9 {
        indistinguishableFromV2.insert(nt.night + "@\(nt.row.startTs)")
    }
    print("\(nt.night.padding(toLength: 12, withPad: " ", startingAt: 0)) \(nt.row.userEdited ? "   yes" : "    no") \(String(format: "%7d", stored.count)) \(f(p1, 8, 2))% \(f(p2, 8, 2))%  \(verdict)")
}
print("""
--------------------------------------------------------------------------------
UNEDITED nights — exact-V1 reproductions: \(v1Match)   exact-V2 reproductions: \(v2Match)   neither exact: \(neither)
EDITED nights whose stored hypnogram is a byte-exact V2 replay (excluded as a V2 reference): \(indistinguishableFromV2.count) of \(nights.filter { $0.row.userEdited }.count)
""")

/// True when this night's stored hypnogram survived as the wearer left it.
func isGenuineEdit(_ nt: Night) -> Bool {
    nt.row.userEdited && !indistinguishableFromV2.contains(nt.night + "@\(nt.row.startTs)")
}

// MARK: - B. Accuracy against the wearer's manual restages

// ONLY nights whose stored hypnogram still differs from a fresh V2 replay are usable as human truth.
// Scoring V2 against a row V2 itself wrote would be self-comparison and would inflate every V2 figure.
let edited = nights.filter { $0.truth != nil && isGenuineEdit($0) }
let selfMatchedNights = nights.filter { $0.row.userEdited && !isGenuineEdit($0) }
print("""

================================================================================
B. ACCURACY vs THE WEARER'S MANUAL RESTAGES  (reference (a), n = \(edited.count) nights)
================================================================================
`userEdited = 1` rows carry the hypnogram the wearer corrected by hand — the only human-labelled
reference in the database. `machine` is the ORIGINAL machine wake total, recovered from the stale
pre-edit `efficiency` column; V1/V2 are fresh replays over the same window.
""")
print("night        inbed  truthW  machW   V1 W   V2 W  V1+vetoW V2+vetoW   dMach     dV1     dV2")
var dMach: [Double] = [], dV1: [Double] = [], dV2: [Double] = [], dV1v: [Double] = [], dV2v: [Double] = []
for nt in edited {
    guard let t = nt.truth else { continue }
    let tw = wakeMinutes(t), w1 = wakeMinutes(nt.v1), w2 = wakeMinutes(nt.v2)
    let w1v = wakeMinutes(nt.v1Veto), w2v = wakeMinutes(nt.v2Veto)
    let mw = nt.machineWakeMin
    if let mw { dMach.append(mw - tw) }
    dV1.append(w1 - tw); dV2.append(w2 - tw)
    if !nt.band.isEmpty { dV1v.append(w1v - tw); dV2v.append(w2v - tw) }
    print("\(nt.night) \(f(nt.row.durMin, 6, 0)) \(f(tw, 7, 0)) \(f(mw ?? .nan, 6, 0)) \(f(w1, 6, 0)) \(f(w2, 6, 0)) \(f(w1v, 9, 0)) \(f(w2v, 8, 0)) \(f((mw ?? .nan) - tw, 7, 0)) \(f(w1 - tw, 7, 0)) \(f(w2 - tw, 7, 0))")
}
func summarise(_ name: String, _ v: [Double]) {
    guard !v.isEmpty else { print("  \(name): no data"); return }
    print("  \(name.padding(toLength: 22, withPad: " ", startingAt: 0)) n=\(v.count)  mean \(f(mean(v), 7, 1))  median \(f(median(v), 7, 1))  sd \(f(sd(v), 6, 1))  range \(f(v.min()!, 6, 0))..\(f(v.max()!, 6, 0))")
}
print("\nWAKE-MINUTE ERROR vs manual restage (positive = OVER-calls wake):")
summarise("machine-as-stored", dMach)
summarise("V1 replay", dV1)
summarise("V2 replay", dV2)
summarise("V1 + band veto", dV1v)
summarise("V2 + band veto", dV2v)

// Per-stage agreement, pooled over every edited night.
print("\n4-CLASS AGREEMENT vs manual restage (epochs pooled over \(edited.count) nights):")
for (name, get) in [("V1", { (n: Night) in n.v1 }), ("V2", { (n: Night) in n.v2 }),
                    ("V1+veto", { (n: Night) in n.v1Veto }), ("V2+veto", { (n: Night) in n.v2Veto })] {
    var c = Confusion(classes: stageOrder)
    var c2 = Confusion(classes: ["wake", "sleep"])
    for nt in edited {
        guard let t = nt.truth else { continue }
        c.merge(confusion(ref: t, pred: get(nt)))
        c2.merge(confusion(ref: toSleepWake(t), pred: toSleepWake(get(nt)), classes: ["wake", "sleep"]))
    }
    print("  \(name.padding(toLength: 9, withPad: " ", startingAt: 0)) 4-class acc \(f(c.accuracy * 100, 5, 1))%  kappa \(f(c.kappa, 6, 3))   |   sleep/wake acc \(f(c2.accuracy * 100, 5, 1))%  kappa \(f(c2.kappa, 6, 3))")
    for s in stageOrder {
        let (sens, spec, n) = c.sensSpec(s)
        print("      \(s.padding(toLength: 6, withPad: " ", startingAt: 0)) sens \(f(sens * 100, 5, 1))%  spec \(f(spec * 100, 5, 1))%  (ref epochs \(n))")
    }
}

// MARK: - C. Accuracy against the strap's own band sleep_state

let banded = nights.filter { !$0.band.isEmpty }
print("""

================================================================================
C. AGREEMENT WITH THE STRAP'S OWN BAND sleep_state  (reference (b), n = \(banded.count) nights)
================================================================================
The v18 @81 high nibble (0 wake / 1 still / 2 asleep / 3 up) is the strap's OWN scored verdict, not a
re-derivation of NOOP's. It carries no light/deep/REM, so this is a sleep-vs-wake comparison only.
STRICT maps band 2 -> sleep and band 0/3 -> wake, and EXCLUDES band 1 ("still", genuinely ambiguous).
""")
for (name, get) in [("V1", { (n: Night) in n.v1 }), ("V2", { (n: Night) in n.v2 }),
                    ("V1+veto", { (n: Night) in n.v1Veto }), ("V2+veto", { (n: Night) in n.v2Veto }),
                    ("stored", { (n: Night) in epochLabels(n.row.stages, start: n.row.startTs, end: n.row.endTs) })] {
    var c = Confusion(classes: ["wake", "sleep"])
    for nt in banded {
        let pred = toSleepWake(get(nt))
        for (i, b) in nt.band.enumerated() where i < pred.count {
            guard b != 1 else { continue }                       // "still" excluded
            c.add(ref: b == SleepStager.bandStateAsleep ? "sleep" : "wake", pred: pred[i])
        }
    }
    let (sens, spec, n) = c.sensSpec("wake")
    print("  \(name.padding(toLength: 9, withPad: " ", startingAt: 0)) acc \(f(c.accuracy * 100, 5, 1))%  kappa \(f(c.kappa, 6, 3))  wake sens \(f(sens * 100, 5, 1))%  wake spec \(f(spec * 100, 5, 1))%  (band-wake epochs \(n), total \(c.total))")
}
// How much of what each stager calls wake does the strap itself dispute?
print("\nDISPUTED WAKE — of the epochs each stager calls wake, what fraction did the strap score \"asleep\"?")
for (name, get) in [("V1", { (n: Night) in n.v1 }), ("V2", { (n: Night) in n.v2 }),
                    ("stored", { (n: Night) in epochLabels(n.row.stages, start: n.row.startTs, end: n.row.endTs) })] {
    var wakeEpochs = 0, disputed = 0, sleepEpochs = 0, reverseDisputed = 0
    for nt in banded {
        let pred = get(nt)
        for (i, b) in nt.band.enumerated() where i < pred.count {
            if pred[i] == "wake" {
                wakeEpochs += 1
                if b == SleepStager.bandStateAsleep { disputed += 1 }
            } else {
                sleepEpochs += 1
                if b == 0 || b == 3 { reverseDisputed += 1 }
            }
        }
    }
    let fwd = wakeEpochs == 0 ? Double.nan : Double(disputed) / Double(wakeEpochs) * 100
    let rev = sleepEpochs == 0 ? Double.nan : Double(reverseDisputed) / Double(sleepEpochs) * 100
    print("  \(name.padding(toLength: 9, withPad: " ", startingAt: 0)) stager-wake epochs \(String(format: "%6d", wakeEpochs)), strap says asleep \(f(fwd, 5, 1))%   |   reverse (stager sleep, strap wake/up) \(f(rev, 5, 1))%")
}

// MARK: - D. The supplement-HR hypothesis

print("""

================================================================================
D. DOES THE WAKE OVER-CALL TRACK OVERNIGHT HR?  (the supplement hypothesis)
================================================================================
The standing inference is that an overnight HR held around 55-60 bpm reads to an HR-led wake detector as
wakefulness. If true, per-night wake error should RISE with mean overnight HR. Tested here on every night
that has a human reference.
""")
print("night        meanHR   truthW   machW    dMach     dV1     dV2")
var hrs: [Double] = [], errM: [Double] = [], errV1: [Double] = [], errV2: [Double] = []
for nt in edited.sorted(by: { $0.meanHR < $1.meanHR }) {
    guard let t = nt.truth, !nt.meanHR.isNaN else { continue }
    let tw = wakeMinutes(t)
    let mw = nt.machineWakeMin ?? .nan
    hrs.append(nt.meanHR); errM.append(mw - tw)
    errV1.append(wakeMinutes(nt.v1) - tw); errV2.append(wakeMinutes(nt.v2) - tw)
    print("\(nt.night) \(f(nt.meanHR, 8, 1)) \(f(tw, 8, 0)) \(f(mw, 7, 0)) \(f(mw - tw, 8, 0)) \(f(wakeMinutes(nt.v1) - tw, 7, 0)) \(f(wakeMinutes(nt.v2) - tw, 7, 0))")
}
for (nm, e) in [("machine-as-stored", errM), ("V1 replay", errV1), ("V2 replay", errV2)] {
    let (r, n, t) = pearson(hrs, e)
    print("  corr(mean overnight HR, \(nm.padding(toLength: 18, withPad: " ", startingAt: 0)) wake error): r = \(f(r, 6, 3))  n = \(n)  t = \(f(t, 6, 2))")
}

// The edited nights span only a narrow HR band, so the test above is underpowered by construction. The
// BAND-disputed-wake fraction needs no human labels, so it can be run over every banded night and covers
// a far wider HR range — a much stronger test of the same hypothesis.
print("""

  WIDER TEST — no human labels needed, so every banded night counts. For each night, the fraction of
  V2's wake epochs that the strap itself scored "asleep" (its false-wake rate by the strap's reckoning)
  against that night's mean overnight HR. If elevated HR drives the over-call, this must rise with HR.
""")
print("  night        meanHR  V2wakeEp  strapDisputed%")
var bhr: [Double] = [], bdisp: [Double] = []
for nt in banded.sorted(by: { $0.meanHR < $1.meanHR }) {
    var wake = 0, disp = 0
    for (i, b) in nt.band.enumerated() where i < nt.v2.count {
        if nt.v2[i] == "wake" { wake += 1; if b == SleepStager.bandStateAsleep { disp += 1 } }
    }
    guard wake >= 10, !nt.meanHR.isNaN else { continue }
    let pct = Double(disp) / Double(wake) * 100
    bhr.append(nt.meanHR); bdisp.append(pct)
    print("  \(nt.night) \(f(nt.meanHR, 7, 1)) \(String(format: "%9d", wake)) \(f(pct, 15, 1))")
}
let (br, bn, bt) = pearson(bhr, bdisp)
print("  corr(mean overnight HR, strap-disputed wake fraction): r = \(f(br, 6, 3))  n = \(bn)  t = \(f(bt, 6, 2))")
if !selfMatchedNights.isEmpty {
    print("""

  NOTE: \(selfMatchedNights.count) `userEdited` night(s) were excluded from the human-reference tests above because
  their stored hypnogram is a byte-exact replay of the CURRENT V2, so scoring V2 against them would be
  self-comparison. The harness asserts no mechanism for the match: \(selfMatchedNights.map { $0.night }.joined(separator: ", "))
""")
}
// Stratify rather than rely on a single correlation — n is small and the relation need not be linear.
let hiCut = 55.0
let hi = edited.filter { $0.meanHR >= hiCut }, lo = edited.filter { $0.meanHR < hiCut }
for (nm, grp) in [("mean HR >= \(Int(hiCut))", hi), ("mean HR <  \(Int(hiCut))", lo)] {
    let e = grp.compactMap { nt -> Double? in
        guard let t = nt.truth, let mw = nt.machineWakeMin else { return nil }
        return mw - wakeMinutes(t)
    }
    guard !e.isEmpty else { print("  \(nm): no nights"); continue }
    print("  \(nm.padding(toLength: 18, withPad: " ", startingAt: 0)) n=\(e.count)  mean machine wake error \(f(mean(e), 7, 1)) min  median \(f(median(e), 7, 1))")
}

// MARK: - E. Machine cohort split — did anything change mid-history?

print("""

================================================================================
E. PER-NIGHT DETAIL (all \(nights.count) sessions)
================================================================================
""")
print("night        edited band inbed  meanHR storedW    V1 W    V2 W  storedEff")
for nt in nights {
    let stored = epochLabels(nt.row.stages, start: nt.row.startTs, end: nt.row.endTs)
    print("\(nt.night) \(nt.row.userEdited ? "   yes" : "    no") \(nt.band.isEmpty ? "   -" : "   Y") \(f(nt.row.durMin, 5, 0)) \(f(nt.meanHR, 7, 1)) \(f(wakeMinutes(stored), 7, 0)) \(f(wakeMinutes(nt.v1), 7, 0)) \(f(wakeMinutes(nt.v2), 7, 0)) \(f(nt.row.efficiency ?? .nan, 10, 3))")
}

if let path = a.csv {
    var out = "night,userEdited,hasBand,inbedMin,meanHR,storedWake,truthWake,machineWake,v1Wake,v2Wake,v1VetoWake,v2VetoWake,storedEff\n"
    for nt in nights {
        let stored = epochLabels(nt.row.stages, start: nt.row.startTs, end: nt.row.endTs)
        let tw = nt.truth.map { String(format: "%.1f", wakeMinutes($0)) } ?? ""
        let mw = nt.machineWakeMin.map { String(format: "%.1f", $0) } ?? ""
        out += "\(nt.night),\(nt.row.userEdited),\(!nt.band.isEmpty),\(String(format: "%.1f", nt.row.durMin)),\(String(format: "%.1f", nt.meanHR)),\(String(format: "%.1f", wakeMinutes(stored))),\(tw),\(mw),\(String(format: "%.1f", wakeMinutes(nt.v1))),\(String(format: "%.1f", wakeMinutes(nt.v2))),\(String(format: "%.1f", wakeMinutes(nt.v1Veto))),\(String(format: "%.1f", wakeMinutes(nt.v2Veto))),\(nt.row.efficiency.map { String(format: "%.4f", $0) } ?? "")\n"
    }
    try out.write(toFile: path, atomically: true, encoding: .utf8)
    FileHandle.standardError.write(Data("wrote \(path)\n".utf8))
}
