import Foundation
import StrandAnalytics
import StrandCore
import WhoopStore

/// Long-range training history uses the same preparation as the Apple observable model.
public enum CoreTrainingHistory {
    public struct Period: Encodable {
        public var start: String, end: String
        public var total: Double?, estimatedTotal: Double?, level: Double?, band: String?
        public var knownDays: Int, unknownDays: Int, estimatedDays: Int, unrecordedDays: Int
        public var measured: Int?, possible: Int?
        init(_ p: TrainingHistoryLanePeriod) {
            start = p.period.start; end = p.period.end; total = p.total
            estimatedTotal = p.estimatedTotal; level = p.level; band = p.band?.rawValue
            knownDays = p.knownDays; unknownDays = p.unknownDays; estimatedDays = p.estimatedDays
            unrecordedDays = p.unrecordedDays; measured = p.measured; possible = p.possible
        }
    }
    public struct Value: Encodable {
        public var start: String, end: String, value: Double?
        init(_ p: TrainingHistoryValue) { start = p.period.start; end = p.period.end; value = p.value }
    }
    public struct Lift: Encodable {
        public var id: String, title: String, values: [Value]
    }
    public struct Choice: Encodable { public var id: String, title: String, sessions: Int }
    public struct Output: Encodable {
        public var span: String, first: String, last: String, resolution: String, today: String
        public var earliest: String?, jumpDay: String?
        public var strength: [Period], cardio: [Period], session: [Period]
        public var lifts: [Lift], choices: [Choice], vo2: [Value], vo2Apple: [Value]
    }

    public static func read(reader: StoreReader, span: String, jumpDay: String?, lifts: [String],
                            maxHR: Double, sex: String, dismissedWorkouts: [String],
                            now: Int = Int(Date().timeIntervalSince1970)) async -> Output {
        let days = TrainingHistoryWindow.allDays
        let from = now - days * 86_400
        let fusion = await TrainingSessionResolver.read(reader: reader, from: from, to: now + 86_400,
                                                        dismissedDetectedSpans: dismissedWorkouts)
        let history = await StrengthHistoryReader.read(store: reader.store, days: days, now: now) { fusion }
        let resolution = await CardioLoadPricing.price(fusion.sessions, reader: reader, maxHR: maxHR, sex: sex,
            dataRevision: 0, cache: CardioLoadCache(), budget: CardioLoadPricing.cardioLoadSessionBudget,
            recompute: false).resolution
        let ratings = await SessionRPEEntry.read(store: reader.store, from: from, to: now + 86_400)
        let today = StoreReader.localDayKey(Date(timeIntervalSince1970: TimeInterval(now)))
        let first = StoreReader.localDayKey(Date(timeIntervalSince1970: TimeInterval(from)))
        let apple = (try? await reader.store.metricSeries(deviceId: MetricResolver.appleHealthSource,
            key: "vo2max", from: first, to: today)) ?? []
        let estimates = await MetricResolver.resolve(store: reader.store, key: "vo2max_est",
            preferredSource: MetricResolver.whoopSource, actualWhoopSource: reader.activeDeviceId,
            from: first, to: today, suppressedSleepWakeDays: [])
        let (source, choices) = TrainingHistoryPreparation.source(workouts: history.workouts,
            templates: history.templates, sessions: fusion.sessions, resolution: resolution, ratings: ratings,
            vo2Estimates: estimates.points.map { ($0.day, $0.value) }, vo2Apple: apple.map { ($0.day, $0.value) },
            today: today, offset: TimeZone.current.secondsFromGMT())
        return output(source: source, choices: choices, span: span, jumpDay: jumpDay, lifts: lifts)
    }

    static func output(source: TrainingHistoryPreparation.Source, choices: [TrainingHistoryPreparation.LiftChoice],
                       span: String, jumpDay: String?, lifts: [String]) -> Output {
        let span = TrainingHistorySpan(rawValue: span) ?? .oneYear
        // The picker bounds on Apple are enforced at the JNI boundary as well.
        let jump = jumpDay.flatMap { day -> String? in
            let calendar = Calendar(identifier: .gregorian)
            guard let (y, m, d) = WeeklyDigestEngine.parseYMD(day), (1...9999).contains(y),
                  (1...12).contains(m), (1...31).contains(d),
                  let date = calendar.date(from: DateComponents(year: y, month: m, day: d)),
                  calendar.component(.month, from: date) == m, calendar.component(.day, from: date) == d,
                  String(format: "%04d-%02d-%02d", y, m, d) == day else { return nil }
            return min(source.today, max(source.earliest ?? source.today, day))
        }
        var unique: [String] = []
        for id in lifts where !unique.contains(id) && unique.count < TrainingHistory.defaultLiftCount { unique.append(id) }
        let end = TrainingHistoryPreparation.end(for: span, jumpedTo: jump, today: source.today)
        let built = TrainingHistoryPreparation.build(source: source, span: span, end: end, chosenLifts: unique)
        return Output(span: span.rawValue, first: built.range.first, last: built.range.last,
            resolution: built.range.resolution.rawValue, today: source.today, earliest: source.earliest, jumpDay: jump,
            strength: built.strength.map(Period.init), cardio: built.cardio.map(Period.init),
            session: built.session.map(Period.init),
            lifts: built.lifts.map { Lift(id: $0.id, title: $0.title, values: $0.values.map(Value.init)) },
            choices: choices.map { Choice(id: $0.id, title: $0.title, sessions: $0.sessions) },
            vo2: built.vo2.map(Value.init), vo2Apple: built.vo2Apple.map(Value.init))
    }
}
