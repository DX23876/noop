import Foundation

/// Pure mapping from NOOP's persisted sleep-stage JSON to the interval list the iOS HealthKit
/// write-back turns into `sleepAnalysis` category samples. Lives here (not in the app target) so
/// the parsing/clamping logic is covered by `swift test` — HealthKit itself can't be unit-tested.
public enum HealthWriteback {

    // MARK: - Heart-rate write-back

    /// The two timestamp shapes the physical-device diagnostic compares. The value in either shape is
    /// still the same measured one-minute mean; only HealthKit's temporal representation changes.
    public enum HeartRateSampleEncoding: String, Codable, CaseIterable, Equatable, Sendable {
        case interval60Seconds
        case pointAtBucketMidpoint
    }

    /// HealthKit-independent input to the HR write planner.
    public struct HeartRateBucket: Equatable, Sendable {
        public let startTs: Int
        public let bpm: Double
        public init(startTs: Int, bpm: Double) {
            self.startTs = startTs
            self.bpm = bpm
        }
    }

    /// One planned HR quantity sample. The bridge adds HealthKit types/units and source-scoped metadata.
    public struct HeartRateSampleDescriptor: Equatable, Sendable {
        public let bucketTs: Int
        public let startTs: Int
        public let endTs: Int
        public let bpm: Double
        public init(bucketTs: Int, startTs: Int, endTs: Int, bpm: Double) {
            self.bucketTs = bucketTs
            self.startTs = startTs
            self.endTs = endTs
            self.bpm = bpm
        }
    }

    /// Convert minute means into the selected timestamp representation. A leading/trailing partial bucket
    /// remains a valid measurement; intervals are clamped at `nowTs`, while point samples sit at the bucket
    /// midpoint but never in the future.
    public static func heartRateSamples(buckets: [HeartRateBucket],
                                        encoding: HeartRateSampleEncoding,
                                        nowTs: Int) -> [HeartRateSampleDescriptor] {
        buckets.compactMap { bucket in
            guard bucket.bpm.isFinite, bucket.bpm > 0, bucket.startTs <= nowTs else { return nil }
            let start: Int
            let end: Int
            switch encoding {
            case .interval60Seconds:
                start = bucket.startTs
                end = max(start, min(bucket.startTs + 60, nowTs))
            case .pointAtBucketMidpoint:
                let point = min(bucket.startTs + 30, nowTs)
                start = point
                end = point
            }
            return HeartRateSampleDescriptor(bucketTs: bucket.startTs, startTs: start, endTs: end,
                                             bpm: bucket.bpm)
        }
    }

    public struct HeartRateExperimentWindow: Codable, Equatable, Sendable {
        public let startTs: Int
        public let endTs: Int
        public init(startTs: Int, endTs: Int) {
            self.startTs = startTs
            self.endTs = endTs
        }
    }

    public struct HeartRateMigrationChunk: Equatable, Sendable {
        public let window: HeartRateExperimentWindow
        public let completesMigration: Bool
        public init(window: HeartRateExperimentWindow, completesMigration: Bool) {
            self.window = window
            self.completesMigration = completesMigration
        }
    }

    /// Next backward migration window. Kept HealthKit-independent so resume/final-boundary behavior
    /// stays deterministic even when the app is terminated between chunks.
    public static func heartRateMigrationChunk(endTs: Int, floorTs: Int,
                                               chunkDays: Int = 14) -> HeartRateMigrationChunk? {
        guard endTs > floorTs, floorTs > 0, chunkDays > 0 else { return nil }
        let start = max(floorTs, endTs - chunkDays * 86_400)
        return .init(window: .init(startTs: start, endTs: endTs),
                     completesMigration: start <= floorTs)
    }

    // MARK: - Shared backward-migration plumbing

    /// Neutral names for the two shapes above. The backward-chunk math is not heart-rate specific —
    /// the HRV/SDNN repair walks history the same way — and both migrations deliberately share ONE
    /// implementation so their resume and final-boundary behavior cannot drift apart.
    public typealias TimeWindow = HeartRateExperimentWindow
    public typealias MigrationChunk = HeartRateMigrationChunk

    /// Next backward chunk, under the neutral name. Same function as `heartRateMigrationChunk`, so the
    /// tests that pin the boundary behavior cover both callers.
    public static func backwardMigrationChunk(endTs: Int, floorTs: Int,
                                              chunkDays: Int) -> MigrationChunk? {
        heartRateMigrationChunk(endTs: endTs, floorTs: floorTs, chunkDays: chunkDays)
    }

    /// The `HKMetadataKeyExternalUUID` value for a nightly-vitals sample.
    ///
    /// ONE definition on purpose. The regular 14-day write-back dedups by deleting exactly the keys it
    /// is about to re-save, so any second writer that spells this differently would leave the first
    /// writer's samples undeleted and duplicate the day. The HRV/SDNN repair is such a second writer,
    /// which is why the format lives here rather than inline at either call site.
    public static func vitalsExternalKey(noopDeviceId: String,
                                         identifier: String,
                                         day: String) -> String {
        "noop:\(noopDeviceId):\(identifier):\(day)"
    }

    /// Pick two non-overlapping dense two-hour runs for the reversible device experiment. A gap of one
    /// missing bucket is tolerated; larger gaps split a run. The bridge supplies an old enough range that
    /// normal 48-hour reconciliation cannot overwrite the experiment while the user checks Health.
    public static func heartRateExperimentWindows(buckets: [HeartRateBucket],
                                                   windowMinutes: Int = 120,
                                                   minimumCoverage: Double = 0.75,
                                                   maximumWindows: Int = 2)
    -> [HeartRateExperimentWindow] {
        guard windowMinutes > 0, maximumWindows > 0 else { return [] }
        let required = max(1, Int((Double(windowMinutes) * minimumCoverage).rounded(.up)))
        let sorted = buckets.sorted { $0.startTs < $1.startTs }
        var runs: [[HeartRateBucket]] = []
        var run: [HeartRateBucket] = []
        for bucket in sorted {
            if let last = run.last, bucket.startTs - last.startTs > 120 {
                if !run.isEmpty { runs.append(run) }
                run = []
            }
            run.append(bucket)
        }
        if !run.isEmpty { runs.append(run) }

        var windows: [HeartRateExperimentWindow] = []
        for dense in runs where dense.count >= required {
            var i = 0
            while i < dense.count, windows.count < maximumWindows {
                let start = dense[i].startTs
                let end = start + windowMinutes * 60
                let covered = dense[i...].prefix { $0.startTs < end }
                if covered.count >= required {
                    windows.append(.init(startTs: start, endTs: end))
                    i += covered.count
                } else {
                    break
                }
            }
            if windows.count == maximumWindows { break }
        }
        return windows
    }

    /// A HealthKit-agnostic sleep stage. The bridge maps these onto `HKCategoryValueSleepAnalysis`
    /// (`awake → .awake`, `light → .asleepCore`, `deep → .asleepDeep`, `rem → .asleepREM`,
    /// `unspecified → .asleepUnspecified` — the honest block for a fragment whose `stagesJSON`
    /// carries no timing).
    public enum StageKind: String, Equatable {
        case awake, light, deep, rem, unspecified
    }

    public struct StageInterval: Equatable {
        public let start: Int   // unix seconds
        public let end: Int     // unix seconds, > start
        public let kind: StageKind
        public init(start: Int, end: Int, kind: StageKind) {
            self.start = start; self.end = end; self.kind = kind
        }
    }

    /// Decode a session's `stagesJSON` into clamped stage intervals for HealthKit.
    ///
    /// Only the on-device SleepStager segment shape (`[{"start","end","stage"}]`, unix seconds)
    /// carries timing, so only it yields intervals. The two aggregate shapes NOOP has also
    /// persisted (`{"deep":min,…}` and `[{"stage","min"}]` — see `WhoopCsvExporter.stageMinutes`)
    /// have no placement information; fabricating positions for them would write fiction into
    /// Health, so they return `[]` and the caller falls back to one `.asleepUnspecified` block.
    ///
    /// Normalization: the stager labels awake as `"wake"`, importers as `"awake"` — both map to
    /// `.awake`. Unknown labels are dropped. Segments are clamped to `[sessionStart, sessionEnd]`
    /// and zero/negative-length segments (before or after clamping) are dropped.
    public static func stageIntervals(stagesJSON: String?,
                                      sessionStart: Int,
                                      sessionEnd: Int) -> [StageInterval] {
        guard sessionEnd > sessionStart,
              let stagesJSON, let data = stagesJSON.data(using: .utf8),
              let segments = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        else { return [] }
        var out: [StageInterval] = []
        for seg in segments {
            // Aggregate shape ([{"stage","min"}]) has no start/end — bail to the no-timing path
            // for the WHOLE session rather than emit a partial mix.
            guard let rawStart = intValue(seg["start"]), let rawEnd = intValue(seg["end"]) else {
                return []
            }
            guard let stage = (seg["stage"] as? String)?.lowercased() else { continue }
            let kind: StageKind?
            switch stage {
            case "wake", "awake": kind = .awake
            case "light":         kind = .light
            case "deep":          kind = .deep
            case "rem":           kind = .rem
            default:              kind = nil
            }
            guard let kind else { continue }
            let start = max(rawStart, sessionStart)
            let end = min(rawEnd, sessionEnd)
            guard end > start else { continue }
            out.append(StageInterval(start: start, end: end, kind: kind))
        }
        return out.sorted { $0.start < $1.start }
    }

    /// JSON numbers arrive as Int, Double, or NSNumber depending on the writer; accept all.
    private static func intValue(_ any: Any?) -> Int? {
        switch any {
        case let i as Int: return i
        case let d as Double: return Int(d)
        default: return nil
        }
    }

    // MARK: - Merged nights (#364)

    /// One stored sleep fragment, as the write-back sees it: the immutable detected key (`startTs`),
    /// the edited onset when present (`effectiveStartTs` — drives the span, never the key, #318),
    /// the wake, and the persisted stage JSON.
    public struct SleepFragment: Equatable {
        public let startTs: Int
        public let effectiveStartTs: Int
        public let endTs: Int
        public let stagesJSON: String?
        public init(startTs: Int, effectiveStartTs: Int, endTs: Int, stagesJSON: String?) {
            self.startTs = startTs; self.effectiveStartTs = effectiveStartTs
            self.endTs = endTs; self.stagesJSON = stagesJSON
        }
    }

    /// One bridged night, folded for the write-back: the `.inBed` span, the merged stage timeline,
    /// the representative dedup key, and the COMPLETE per-fragment key set for deletion.
    public struct MergedSleepEntry: Equatable {
        /// The group's dedup key: the EARLIEST fragment's immutable detected `startTs` (a user edit
        /// moves the span via `effectiveStartTs`, never this key, so the entry keeps its identity).
        public let keyStartTs: Int
        /// Earliest edited onset → latest wake across the group: the one `.inBed` span.
        public let spanStart: Int
        public let spanEnd: Int
        /// The fragments' stage intervals in time order — a fragment with no decodable timing
        /// contributes one honest `.unspecified` block over its own window — with every
        /// inter-fragment seam as an explicit `.awake` interval.
        public let intervals: [StageInterval]
        /// EVERY fragment's immutable `startTs`, ascending. The delete predicate must carry all of
        /// them: a night previously exported as two entries would otherwise orphan the absorbed
        /// fragment's old entry when it becomes one.
        public let allKeyStartTs: [Int]
        public init(keyStartTs: Int, spanStart: Int, spanEnd: Int,
                    intervals: [StageInterval], allKeyStartTs: [Int]) {
            self.keyStartTs = keyStartTs; self.spanStart = spanStart; self.spanEnd = spanEnd
            self.intervals = intervals; self.allKeyStartTs = allKeyStartTs
        }
    }

    /// Fold bridged night groups (#364) into write-back entries — one `.inBed` span per night with
    /// the mid-night wake seams as explicit `.awake` intervals, matching what the daily totals
    /// already score (#561/#777) and what Oura / Apple Watch write into Health. `groups` comes from
    /// `SleepStageTotals.bridgedNightGroups` (this package deliberately doesn't depend on the
    /// analytics package, so the grouping happens in the caller). Fragments are re-sorted by
    /// effective onset defensively; a zero/negative-length fragment contributes no interval but
    /// keeps its key in the delete set; a group with no positive span is skipped entirely.
    public static func mergedSleepPlan(groups: [[SleepFragment]]) -> [MergedSleepEntry] {
        var out: [MergedSleepEntry] = []
        for group in groups where !group.isEmpty {
            let frags = group.sorted { $0.effectiveStartTs < $1.effectiveStartTs }
            var intervals: [StageInterval] = []
            var prevEnd: Int? = nil
            var spanStart: Int? = nil
            for f in frags {
                guard f.endTs > f.effectiveStartTs else { continue }
                if spanStart == nil { spanStart = f.effectiveStartTs }
                if let p = prevEnd, f.effectiveStartTs > p {
                    intervals.append(StageInterval(start: p, end: f.effectiveStartTs, kind: .awake))
                }
                let stages = stageIntervals(stagesJSON: f.stagesJSON,
                                            sessionStart: f.effectiveStartTs, sessionEnd: f.endTs)
                if stages.isEmpty {
                    intervals.append(StageInterval(start: f.effectiveStartTs, end: f.endTs,
                                                   kind: .unspecified))
                } else {
                    intervals.append(contentsOf: stages)
                }
                prevEnd = max(prevEnd ?? f.endTs, f.endTs)
            }
            guard let start = spanStart, let end = prevEnd, end > start else { continue }
            out.append(MergedSleepEntry(
                keyStartTs: frags.map(\.startTs).min() ?? 0,
                spanStart: start,
                spanEnd: end,
                intervals: intervals,
                allKeyStartTs: frags.map(\.startTs).sorted()))
        }
        return out
    }
}
