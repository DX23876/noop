import Foundation
import StrandAnalytics
import WhoopStore

/// How the Sleep screens turn stored sleep blocks into the night they show (Android plan E-3, moved from
/// `SleepView` and `SleepModel` so the Apple and the Android Sleep screens pick the same main night): blocks are
/// grouped by the calendar day they end on, each day's main night is the bridged group `SleepStageTotals`
/// selects, a sleepless lead stub is dropped from its displayed onset, and everything outside the group is a nap.
public enum SleepNight {
    /// Longest a leading block can be and still be treated as a spurious pre-sleep awake stub (lying in bed
    /// before sleep). Generous (a few hours) because the reporter's stub ran 21:41 → 00:27 — ~2h45m of
    /// pre-sleep awake — so a tight cap missed it (#736). The real guard against swallowing a genuine first
    /// sleep fragment is `preOnsetStubAsleepMaxMin`: a stub must be essentially SLEEPLESS, which a real sleep
    /// block never is. The cap only stops a pathological all-day awake block from being silently dropped.
    public static let preOnsetStubMaxMin: Double = 240
    /// Most asleep minutes a fragment can carry and still count as a (sleepless) pre-onset awake stub. A real
    /// first sleep fragment of a biphasic night carries far more, so it's never mistaken for a stub. (#736)
    public static let preOnsetStubAsleepMaxMin: Double = 3
    /// A leading pre-onset fragment carrying SOME sleep is still spurious when it is minor RELATIVE to the
    /// night's main block: its asleep minutes are below this fraction of the largest fragment's. A genuine
    /// biphasic first sleep is comparable to the main block (well above this) and is kept; only a small stray
    /// lead is dropped. Extends the essentially-sleepless `preOnsetStubAsleepMaxMin` rule (#736), which missed
    /// a lead carrying a few minutes more than 3. Mirrors Android PRE_ONSET_STUB_MINOR_FRAC. (#259)
    public static let preOnsetStubMinorFrac: Double = 0.15
    /// Absolute floor (ASLEEP minutes) under the #259 relative "minor lead" test: a leading fragment that
    /// carries at least this much real sleep is a genuine first sleep — a real sleep episode — and is NEVER
    /// a spurious pre-onset lead, however large the main block is. Without it a long main sleep inflates the
    /// 15% relative bar (a 6h night → ~54 min) so a genuine ~34-min first sleep was swallowed and the shown
    /// bedtime jumped hours late, hiding the real onset the bridged night (and the Health write-back, #364)
    /// already spans. 20 min ≈ the shortest standalone sleep episode; below it a handful of asleep minutes
    /// beside a long night is a stray lead. (bridged-night headline: a real 2026-07-14 12:16 first sleep hidden
    /// behind the 1:29 main block)
    public static let preOnsetStubMinorAsleepFloorMin: Double = 20

    /// Pure stub test on a fragment's span + asleep minutes, so the rule is unit-testable without decoding
    /// JSON or building a view. Spurious when BRIEF and EITHER essentially sleepless OR minor relative to the
    /// main block (`refAsleepMin`, the group's largest asleep span): asleep below `preOnsetStubMinorFrac` of
    /// it AND below the absolute `preOnsetStubMinorAsleepFloorMin` real-sleep-episode floor. `refAsleepMin`
    /// defaults to 0 (relative test off). (#736 / #259)
    public static func isPreOnsetAwakeStub(spanMin: Double, asleepMin: Double, refAsleepMin: Double = 0) -> Bool {
        guard spanMin <= preOnsetStubMaxMin else { return false }
        if asleepMin <= preOnsetStubAsleepMaxMin { return true }
        // #259 relative "minor lead" test, floored: a real sleep episode (>= the floor) is never a stray
        // lead, so a long main block can't inflate the 15% bar past a genuine short first sleep.
        return refAsleepMin > 0
            && asleepMin < preOnsetStubMinorFrac * refAsleepMin
            && asleepMin < preOnsetStubMinorAsleepFloorMin
    }

    /// Minutes per stage of a night or a fragment.
    public struct Minutes: Equatable, Sendable {
        public var awake: Double, light: Double, deep: Double, rem: Double
        public init(awake: Double = 0, light: Double = 0, deep: Double = 0, rem: Double = 0) {
            self.awake = awake; self.light = light; self.deep = deep; self.rem = rem
        }
        /// All stages (includes awake): time in bed.
        public var total: Double { awake + light + deep + rem }
        /// Asleep time: total minus awake.
        public var asleep: Double { light + deep + rem }
    }

    /// One stretch of one stage, in seconds from a reference onset. `stage` is "awake", "light", "deep" or "rem".
    public struct Interval: Equatable, Sendable {
        public var stage: String, start: Double, end: Double
        public init(stage: String, start: Double, end: Double) { self.stage = stage; self.start = start; self.end = end }
    }

    /// Decode the imported stagesJSON dict of MINUTES {"light","deep","rem","awake"}; nil when it is not that
    /// format or carries no minutes.
    public static func minutes(_ json: String?) -> Minutes? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else { return nil }
        func val(_ key: String) -> Double {
            if let n = dict[key] as? NSNumber { return n.doubleValue }
            if let d = dict[key] as? Double { return d }
            if let i = dict[key] as? Int { return Double(i) }
            return 0
        }
        let m = Minutes(awake: val("awake"), light: val("light"), deep: val("deep"), rem: val("rem"))
        return m.total > 0 ? m : nil
    }

    /// Decode the COMPUTED stagesJSON segment array [{"start":epoch,"end":epoch,"stage":"wake"|"light"|"deep"|
    /// "rem"}] into stage minutes plus the real timeline, in seconds from `sessionStart`. The on-device stager
    /// calls awake "wake". (#77)
    public static func segments(_ json: String?, sessionStart: Int) -> (minutes: Minutes, intervals: [Interval])? {
        guard let json, let data = json.data(using: .utf8),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
              !arr.isEmpty else { return nil }
        var minutes = Minutes()
        var intervals: [Interval] = []
        for seg in arr {
            guard let rawStart = (seg["start"] as? NSNumber)?.intValue,
                  let end = (seg["end"] as? NSNumber)?.intValue,
                  let name = seg["stage"] as? String else { continue }
            // #259: trim each segment to the effective onset (`sessionStart`) so a hand-edited bedtime the
            // raw was too sparse to re-stage (WHOOP 4.0) can't sum pre-onset stages past time-in-bed — nor
            // draw bars before the onset. No-op when segments already start at/after it (the common case).
            let start = max(rawStart, sessionStart)
            guard end > start else { continue }
            let m = Double(end - start) / 60.0
            let stage: String
            switch name {
            case "wake", "awake": stage = "awake"; minutes.awake += m
            case "light": stage = "light"; minutes.light += m
            case "deep": stage = "deep"; minutes.deep += m
            case "rem": stage = "rem"; minutes.rem += m
            default: continue
            }
            intervals.append(Interval(stage: stage, start: TimeInterval(start - sessionStart),
                                      end: TimeInterval(end - sessionStart)))
        }
        return minutes.total > 0 ? (minutes, intervals) : nil
    }

    /// A fragment's asleep minutes, whichever stages format it stores: the stub test must read both, since a
    /// computed night's segment array is not the imported minutes dict. (2026-07-14 night)
    public static func asleepMinutes(_ json: String?, effectiveStartTs: Int) -> Double {
        minutes(json)?.asleep ?? segments(json, sessionStart: effectiveStartTs)?.minutes.asleep ?? 0
    }

    /// The browsable day list: every block grouped by the calendar day it ENDS on, newest day first, blocks
    /// within a day oldest to newest. Each day is one night stop. (#170)
    public static func days(_ sessions: [CachedSleepSession], calendar: Calendar = .current) -> [[CachedSleepSession]] {
        func endDay(_ s: CachedSleepSession) -> Date {
            calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(s.endTs)))
        }
        let groups = Dictionary(grouping: sessions, by: endDay)
        return groups.keys.sorted(by: >).map { key in
            (groups[key] ?? []).sorted { $0.effectiveStartTs < $1.effectiveStartTs }
        }
    }

    /// The day's MAIN-night group: the winning block plus the adjacent fragments bridged into it, ascending by
    /// effective onset (`SleepStageTotals.mainNightGroupIndices`). Only blocks outside it are naps. (#561 / #555)
    public static func mainGroup(_ sessions: [CachedSleepSession], offsetSec: Int,
                                 habitualMidsleepSec: Int? = nil) -> [CachedSleepSession] {
        guard let idx = SleepStageTotals.mainNightGroupIndices(
            sessions.map { SleepStageTotals.NightBlock(start: $0.effectiveStartTs, end: $0.endTs) },
            offsetSec: offsetSec, habitualMidsleepSec: habitualMidsleepSec) else { return [] }
        return idx.map { sessions[$0] }.sorted { $0.effectiveStartTs < $1.effectiveStartTs }
    }

    /// The night's DISPLAYED onset (bedtime): the first fragment that is not a spurious leading pre-onset awake
    /// stub, falling back to the earliest onset when the whole group is stub-like. (#736, #259)
    public static func onsetTs(_ group: [CachedSleepSession]) -> Int {
        guard let first = group.first else { return 0 }
        let refAsleepMin = group.map { asleepMinutes($0.stagesJSON, effectiveStartTs: $0.effectiveStartTs) }.max() ?? 0
        for frag in group {
            let spanMin = Double(frag.endTs - frag.effectiveStartTs) / 60.0
            let asleepMin = asleepMinutes(frag.stagesJSON, effectiveStartTs: frag.effectiveStartTs)
            if !isPreOnsetAwakeStub(spanMin: spanMin, asleepMin: asleepMin, refAsleepMin: refAsleepMin) {
                return frag.effectiveStartTs
            }
        }
        return first.effectiveStartTs
    }

    /// One day's main night, merged from its group: onset to wake, the stage minutes summed over the shown
    /// fragments, their timeline in seconds from the onset with the gaps between fragments as awake, and the
    /// fragments themselves (`group` the whole bridged group, `shown` without a dropped lead stub).
    public struct Main: Sendable {
        public var onset: Int, wake: Int
        public var minutes: Minutes
        public var intervals: [Interval]
        public var group: [CachedSleepSession], shown: [CachedSleepSession]
    }

    /// The main night of one day's blocks, nil when its group decodes to no asleep minutes. (#170, #318, #555,
    /// #561, #736)
    public static func main(_ sessions: [CachedSleepSession], offsetSec: Int,
                            habitualMidsleepSec: Int?) -> Main? {
        let group = mainGroup(sessions, offsetSec: offsetSec, habitualMidsleepSec: habitualMidsleepSec)
        guard let last = group.last else { return nil }
        let onset = onsetTs(group), wake = last.endTs
        let shown = Array(group.drop { $0.effectiveStartTs < onset })
        var total = Minutes()
        var intervals: [Interval] = []
        for frag in shown {
            if let seg = segments(frag.stagesJSON, sessionStart: frag.effectiveStartTs), seg.minutes.total > 0 {
                total.awake += seg.minutes.awake; total.light += seg.minutes.light
                total.deep += seg.minutes.deep; total.rem += seg.minutes.rem
                let shift = TimeInterval(frag.effectiveStartTs - onset)
                for iv in seg.intervals {
                    intervals.append(Interval(stage: iv.stage, start: iv.start + shift, end: iv.end + shift))
                }
            } else if let m = minutes(frag.stagesJSON), m.total > 0 {
                total.awake += m.awake; total.light += m.light
                total.deep += m.deep; total.rem += m.rem
            }
        }
        for (prev, next) in zip(shown, shown.dropFirst()) {
            let gapStart = prev.endTs, gapEnd = next.effectiveStartTs
            guard gapEnd > gapStart else { continue }
            intervals.append(Interval(stage: "awake", start: TimeInterval(gapStart - onset),
                                      end: TimeInterval(gapEnd - onset)))
        }
        guard total.asleep > 0 else { return nil }
        return Main(onset: onset, wake: wake, minutes: total, intervals: intervals.sorted { $0.start < $1.start },
                    group: group, shown: shown)
    }
}
