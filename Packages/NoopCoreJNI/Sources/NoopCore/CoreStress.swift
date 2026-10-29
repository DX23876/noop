import Foundation
import StrandAnalytics
import StrandCore
import WhoopStore

/// Today's daytime stress for Android (parity plan 1.3): the reads, the lens and the scoring Apple's
/// `StressDayCurve` runs (`DaytimeStressDay`), from the core's union reader instead of Room. The fingerprint lets
/// the caller skip the read while today's heart rate has not moved.
public enum CoreStress {
    public struct Hour: Encodable {
        public var hour: Int, startTs: Int, level: Double?, meanHR: Double?, rmssd: Double?, masked: Bool
        init(_ p: DaytimeStress.HourPoint) {
            hour = p.hour; startTs = p.startTs; level = p.level; meanHR = p.meanHR; rmssd = p.rmssd
            masked = p.maskedForActivity
        }
    }

    public struct Output: Encodable {
        public var hours: [Hour], timeline: [Hour]
        public var sustainedHigh: Bool, sustainedRun: Int, dayMean: Double?, peak: Hour?
        public var activityMaskedHours: Int, highStressMinutes: Int, hrOnlyFallback: Bool
        public var usesPersonalBaseline: Bool
    }

    /// The union heart-rate fingerprint of today so far; empty when nothing could be read.
    public static func fingerprint(reader: StoreReader, now: Date = Date(), calendar: Calendar = .current) async -> String {
        await reader.hrFingerprintUnion(from: Int(calendar.startOfDay(for: now).timeIntervalSince1970),
                                        to: Int(now.timeIntervalSince1970))
    }

    @MainActor
    public static func day(reader: StoreReader, personalBaseline: Bool, now: Date = Date(),
                           calendar: Calendar = .current) async -> Output {
        guard let inputs = await DaytimeStressDay.inputs(source: reader, now: now, calendar: calendar,
                                                         personalBaseline: personalBaseline) else {
            return output(.empty, personal: false)
        }
        let result = DaytimeStress.analyze(hr: inputs.hr, rr: inputs.rr, gravity: inputs.gravity,
                                           tzOffsetSeconds: inputs.tzOffsetSeconds, mode: inputs.mode,
                                           includeTimeline: true)
        if case .baselineRelative = inputs.mode { return output(result, personal: true) }
        return output(result, personal: false)
    }

    static func output(_ r: DaytimeStress.Result, personal: Bool) -> Output {
        Output(hours: r.hours.map(Hour.init), timeline: r.timeline.map(Hour.init), sustainedHigh: r.sustainedHigh,
               sustainedRun: r.sustainedRun, dayMean: r.dayMean, peak: r.peak.map(Hour.init),
               activityMaskedHours: r.activityMaskedHours, highStressMinutes: r.highStressMinutes,
               hrOnlyFallback: r.hrOnlyFallback, usesPersonalBaseline: personal)
    }
}
