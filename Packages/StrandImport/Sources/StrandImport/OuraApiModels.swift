import Foundation

// MARK: - Neutral models emitted by OuraApiParser (network-free; the app-target writer maps them to WhoopStore).

/// One heart-rate sample (→ hrSample on write). `ts` is unix seconds, `bpm` is positive.
public struct OuraHRPoint: Sendable, Equatable {
    public let ts: Int
    public let bpm: Int
    public init(ts: Int, bpm: Int) { self.ts = ts; self.bpm = bpm }
}

/// One Oura detailed sleep period: the shared `session` (incl. decoded stages) plus the rich extras the
/// shared model can't hold. `movement30s` → sleepSession.motionJSON; `hr` → hrSample. (HRV samples stay
/// in the raw archive only — there is no rMSSD-per-sample table; the per-night average is on `session`.)
public struct OuraSleepPeriod: Sendable, Equatable {
    public var session: WearableSleepSession
    public var movement30s: [Int]
    public var hr: [OuraHRPoint]
    public init(session: WearableSleepSession, movement30s: [Int], hr: [OuraHRPoint]) {
        self.session = session; self.movement30s = movement30s; self.hr = hr
    }
}

/// One extra daily scalar Oura returns that the wide `dailyMetric` columns don't hold (→ metricSeries on
/// write). `key` is the metricSeries key; the brand's OWN scores use a `ref_` prefix and its contributor
/// breakdowns an `oura_` prefix, so they are browseable but never mistaken for a NOOP score.
public struct OuraDailyExtra: Sendable, Equatable {
    public let day: String
    public let key: String
    public let value: Double
    public init(day: String, key: String, value: Double) { self.day = day; self.key = key; self.value = value }
}

/// One Oura workout (→ the `workout` table on write). Times are UTC; metric fields nil when absent.
public struct OuraWorkout: Sendable, Equatable {
    public let start: Date
    public let end: Date
    public let activity: String
    public let source: String
    public let energyKcal: Double?
    public let distanceM: Double?
    public init(start: Date, end: Date, activity: String, source: String, energyKcal: Double?, distanceM: Double?) {
        self.start = start; self.end = end; self.activity = activity; self.source = source
        self.energyKcal = energyKcal; self.distanceM = distanceM
    }
}
