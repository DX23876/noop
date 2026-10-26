import Foundation
import StrandAnalytics
import StrandCore
import WhoopStore

/// The Training Load screen for the Android app (Android parity plan 2.3): the same reads the Apple
/// `TrainingLoadModel.snapshot` makes, through the store, and the same computation (`TrainingLoadPreparation.prepare`),
/// handed to Kotlin as plain values. Wording and layout stay with each platform; every number and every state the
/// screen shows comes from here.
public enum CoreTrainingLoad {
    /// One lane as the screen reads it (`TrainingLoadPreparation.Lane`).
    public struct Lane: Encodable {
        public var sevenDayTotal: Double, sevenDayWorkingSets: Int
        public var percent: Double?
        public var band: String?, guardState: String?, daysBelowUsual: Int, readingDay: String?
        public var maturity: String
        public var isLowerBound: Bool
        public var monotony: Double?, strain: Double?
        public var weekOverWeek: Double?
        public var measuredCount: Int, possibleCount: Int

        init(_ lane: TrainingLoadPreparation.Lane) {
            sevenDayTotal = lane.sevenDayTotal; sevenDayWorkingSets = lane.sevenDayWorkingSets
            percent = lane.trend?.percentChange
            band = lane.reading?.band?.rawValue; guardState = lane.reading?.guardState.rawValue
            daysBelowUsual = lane.reading?.daysBelowUsual ?? 0; readingDay = lane.reading?.day
            maturity = lane.relative.maturity.rawValue
            isLowerBound = lane.isLowerBound
            monotony = lane.distribution?.monotony; strain = lane.distribution?.strain
            weekOverWeek = lane.weekOverWeek
            measuredCount = lane.measuredCount; possibleCount = lane.possibleCount
        }
    }

    /// A verdict (`LaneVerdict`): `status` with a `TrainingStatus`, or `loadOnly` with a band.
    public struct Verdict: Encodable {
        public var kind: String, value: String
        init?(_ verdict: LaneVerdict?) {
            switch verdict {
            case let .status(status): kind = "status"; value = status.rawValue
            case let .loadOnly(band): kind = "loadOnly"; value = band.rawValue
            case nil: return nil
            }
        }
    }

    /// The page's one statement (`TrainingStatusModel.TrainingStatement`), its case and arguments.
    public struct Statement: Encodable {
        public var kind: String
        public var lane: String?, verdict: Verdict?, low: String?, high: String?, severity: String?
        public var flag: Bool?

        init(_ statement: TrainingStatusModel.TrainingStatement) {
            switch statement {
            case .noHistory: kind = "noHistory"
            case let .laneOnly(lane, verdict): kind = "laneOnly"; self.lane = lane.rawValue; self.verdict = Verdict(verdict)
            case let .aligned(verdict): kind = "aligned"; self.verdict = Verdict(verdict)
            case let .oneBehind(lane): kind = "oneBehind"; self.lane = lane.rawValue
            case let .split(low, high, severity):
                kind = "split"; self.low = low.rawValue; self.high = high.rawValue; self.severity = severity.rawValue
            case let .excessive(lane, strained): kind = "excessive"; self.lane = lane.rawValue; flag = strained
            case let .bothExcessive(strained): kind = "bothExcessive"; flag = strained
            case let .spinning(lane, otherAlsoHigh): kind = "spinning"; self.lane = lane.rawValue; flag = otherAlsoHigh
            case .bothSpinning: kind = "bothSpinning"
            case .strainedRecovery: kind = "strainedRecovery"
            }
        }
    }

    public struct Room: Encodable {
        public var beforeAbove: Double, beforeWellAbove: Double?
    }

    public struct Reading: Encodable {
        public var day: String, value: Double, segment: String
        init(_ r: VO2maxReading) { day = r.day; value = r.value; segment = r.segment }
    }

    public struct Output: Encodable {
        public var strength: Lane, cardio: Lane, session: Lane
        public var ratios: [Ratio]
        public var history: [Week]
        public var strengthVerdict: Verdict?, cardioVerdict: Verdict?
        public var statement: Statement
        public var recoveryState: String, strainedNights: Int, nightsRead: Int, recoveryNights: Int
        public var flaggingOnLatestNight: [String], readOnLatestNight: [String]
        public var strengthAdaptation: String, cardioAdaptation: String
        public var strengthRoom: Room?, cardioRoom: Room?, strengthSettles: String?, cardioSettles: String?
        public var sustainedLanes: [String]?, sustainedWeeks: Int?
        public var rising: Int, unclear: Int, falling: Int
        public var vo2Primary: Reading?, vo2Line: [Reading], vo2Apple: Reading?
        public var evidence: String, evidenceSource: String?, evidenceSport: String?, evidenceSessions: Int?
        public var provisionalBand: String?
        public var cardioMeasured: Bool
        public var appleSource: String
        public var trustedShare: Double
    }

    public struct Ratio: Encodable {
        public var day: String, strength: Double?, cardio: Double?
    }

    public struct Week: Encodable {
        public var day: String, strength: String?, cardio: String?
    }

    /// Reads what `TrainingLoadModel.snapshot` reads and runs the shared computation. `maxHR` and `sex` are the
    /// wearer's, as the cardio load is priced on the iPhone (`Repository.cardioLoadMaxHR`).
    public static func read(reader: StoreReader, maxHR: Double, sex: String, dismissedWorkoutSpans: [String],
                            now: Int = Int(Date().timeIntervalSince1970)) async -> Output {
        let store = reader.store
        let cache = CardioLoadCache()
        let days = TrainingLoadPreparation.historyDays
        let from = now - days * 86_400
        let offset = TimeZone.current.secondsFromGMT()
        let fusion = await TrainingSessionResolver.read(reader: reader, from: from, to: now + 86_400,
                                                        dismissedDetectedSpans: dismissedWorkoutSpans)
        let strengthHistory = await StrengthHistoryReader.read(store: store, days: days, now: now) { fusion }
        let resolution = await CardioLoadPricing.price(fusion.sessions, reader: reader, maxHR: maxHR, sex: sex,
                                                       dataRevision: 0, cache: cache,
                                                       budget: CardioLoadPricing.cardioLoadSessionBudget,
                                                       recompute: false).resolution
        let ratings = await SessionRPEEntry.read(store: store, from: from, to: now + 86_400)
        let today = StoreReader.localDayKey(Date(timeIntervalSince1970: TimeInterval(now)))
        let dailyRows = await CoreTrainingReports.dailyMetrics(reader: reader,
            from: StoreReader.localDayKey(Date(timeIntervalSince1970: TimeInterval(from))), to: today)
        let vo2 = await vo2maxReadings(reader: reader, now: now)
        let prepared = TrainingLoadPreparation.prepare(
            strengthHistory: strengthHistory, unified: fusion.sessions, cardioResolution: resolution,
            rpeEntries: ratings, dailyRows: dailyRows, vo2Estimates: vo2.estimates, vo2Apple: vo2.apple,
            today: today, now: now, offset: offset)
        return output(prepared)
    }

    /// Both VO2max series as `TrainingLoadModel.vo2maxReadings` reads them: NOOP's weekly estimate tagged with its
    /// estimator, and Apple Watch's measured readings.
    static func vo2maxReadings(reader: StoreReader, now: Int) async -> (estimates: [VO2maxReading], apple: [VO2maxReading]) {
        let store = reader.store
        let from = StoreReader.localDayKey(Date(timeIntervalSince1970: TimeInterval(now - 90 * 86_400)))
        let to = StoreReader.localDayKey(Date(timeIntervalSince1970: TimeInterval(now + 86_400)))
        let apple = ((try? await store.metricSeries(deviceId: MetricResolver.appleHealthSource, key: "vo2max",
                                                    from: from, to: to)) ?? [])
            .map { VO2maxReading(day: $0.day, value: $0.value, segment: MetricResolver.appleHealthSource) }
        let resolution = await MetricResolver.resolve(store: store, key: "vo2max_est",
                                                      preferredSource: MetricResolver.whoopSource,
                                                      actualWhoopSource: reader.activeDeviceId, from: from, to: to,
                                                      suppressedSleepWakeDays: [])
        var estimates: [VO2maxReading] = []
        for point in resolution.points {
            let tag = point.source.hasSuffix("-noop")
                ? try? await store.scoreInputSource(deviceId: point.source, day: point.day, key: "vo2max_est") : nil
            estimates.append(VO2maxReading(day: point.day, value: point.value, segment: (tag ?? nil) ?? point.source))
        }
        return (estimates, apple)
    }

    static func output(_ p: TrainingLoadPreparation.Prepared) -> Output {
        func room(_ r: LaneHeadroom?) -> Room? { r.map { Room(beforeAbove: $0.beforeAbove, beforeWellAbove: $0.beforeWellAbove) } }
        return Output(
            strength: Lane(p.strength), cardio: Lane(p.cardio), session: Lane(p.session),
            ratios: p.ratios.map { Ratio(day: $0.day, strength: $0.strength, cardio: $0.cardio) },
            history: p.history.map { Week(day: $0.day, strength: $0.strength?.rawValue, cardio: $0.cardio?.rawValue) },
            strengthVerdict: Verdict(p.strengthVerdict), cardioVerdict: Verdict(p.cardioVerdict),
            statement: Statement(p.statement),
            recoveryState: p.recovery.state.rawValue, strainedNights: p.recovery.strainedNights,
            nightsRead: p.recovery.nightsRead, recoveryNights: TrainingStatusModel.recoveryNights,
            flaggingOnLatestNight: p.recovery.flaggingOnLatestNight, readOnLatestNight: p.recovery.readOnLatestNight,
            strengthAdaptation: p.strengthAdaptation.state.rawValue,
            cardioAdaptation: p.cardiovascularAdaptation.state.rawValue,
            strengthRoom: room(p.outlook.strengthRoom), cardioRoom: room(p.outlook.cardioRoom),
            strengthSettles: p.outlook.strengthSettles, cardioSettles: p.outlook.cardioSettles,
            sustainedLanes: p.sustained?.lanes.map(\.rawValue), sustainedWeeks: p.sustained?.weeks,
            rising: p.response.rising, unclear: p.response.unclear, falling: p.response.falling,
            vo2Primary: p.vo2display.primary.map(Reading.init), vo2Line: p.vo2display.line.readings.map(Reading.init),
            vo2Apple: p.vo2display.appleLatest.map(Reading.init),
            evidence: p.cardioEvidence.evidence.rawValue, evidenceSource: p.cardioEvidence.source.rawValue,
            evidenceSport: p.cardioEvidence.efficiency?.sport, evidenceSessions: p.cardioEvidence.efficiency?.sessions,
            provisionalBand: p.provisionalStrengthRing?.band.rawValue,
            cardioMeasured: p.cardioMeasured,
            appleSource: MetricResolver.appleHealthSource,
            trustedShare: TrainingLoad.trustedRatedShare)
    }
}
