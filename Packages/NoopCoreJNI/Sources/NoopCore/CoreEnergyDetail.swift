import Foundation
import StrandAnalytics
import StrandCore
import WhoopStore

/// The Energy detail screen on Android (parity plan 2.3), after Apple's `EnergyDetailView`: the last 30 days'
/// summaries, one day's burn-rate curve with its training bands and the split of active energy, and a comparison
/// curve (the day before, or the median of the 7 or 30 days before). The day rate and the reference curve are read
/// as `Repository.energyDayRate` and `Repository.energyReferenceRate` read them; every figure and label arrives
/// resolved, so the Kotlin screen only draws it.
enum CoreEnergyDetail {
    static let historyDays = 30

    struct Output: Encodable {
        var today: String
        var day: String
        var summaries: [Summary]
        var selected: Summary?
        var points: [Point]
        var bands: [Band]
        var trainingKcal: Double?
        var movementKcal: Double?
        var comparison: String
        var comparisonPoints: [Point]
        var comparisonCaption: String?
        var comparisonUnavailable: String?
    }
    struct Summary: Encodable {
        var day: String
        var total: Double?, active: Double?, basal: Double?, bmr24h: Double?
        var projectedLow: Double?, projectedHigh: Double?
        var source: String, sourceLabel: String
        var confidence: String, confidenceLabel: String
        var compactLine: String?
    }
    struct Point: Encodable { var start: Double, duration: Double, kcalPerMinute: Double }
    struct Band: Encodable { var start: Double, end: Double, sport: String }

    @MainActor
    static func read(reader: StoreReader, settings: CoreGoals.Settings, day requested: String?, comparison: String,
                     now: Date = Date()) async -> Output {
        let today = StoreReader.localDayKey(now)
        let day = requested.flatMap { $0.isEmpty ? nil : $0 } ?? today
        let mode = ["previousDay", "sevenDay", "thirtyDay"].contains(comparison) ? comparison : "sevenDay"
        guard let profile = settings.energyProfile else {
            return Output(today: today, day: day, summaries: [], points: [], bands: [], comparison: mode, comparisonPoints: [])
        }
        // The adaptive estimate is the summaries' prior, as `energySummaries` reads it on Apple.
        let prior = await NutritionReads.adaptiveEstimate(reader: reader, asOf: now)?.estimatedDailyKcal
        let summaries = await CoreEnergyPlan.summaries(reader: reader, settings: settings, profile: profile,
                                                       days: historyDays, now: now, adaptivePrior: prior).map(summary)
        let rate = await dayRate(reader: reader, settings: settings, day: day)
        let selected = summaries.last { $0.day == day }
        var training: Double?, movement: Double?
        if let fraction = rate.fraction, let active = selected?.active {
            training = active * fraction
            movement = active - active * fraction
        }
        var compare: [EnergyBurnRate.Point] = []
        var caption: String?, unavailable: String?
        if mode == "previousDay" {
            if let previous = previousDay(day) {
                compare = await dayRate(reader: reader, settings: settings, day: previous).points
                if compare.isEmpty { unavailable = String(localized: "The day before has no minute-by-minute record.") }
            }
        } else {
            let window = mode == "sevenDay" ? 7 : 30
            if let reference = await referenceRate(reader: reader, profile: profile, before: day, windowDays: window) {
                compare = reference.points
                caption = String(localized: "Median of \(reference.sampleDays) of the last \(reference.windowDays) days")
            } else {
                unavailable = String(localized: "Not enough fully measured days yet to show a \(window)-day average.")
            }
        }
        func points(_ p: [EnergyBurnRate.Point]) -> [Point] {
            p.map { Point(start: $0.startSeconds, duration: $0.durationSeconds, kcalPerMinute: $0.kcalPerMinute) }
        }
        return Output(today: today, day: day, summaries: summaries, selected: selected, points: points(rate.points),
                      bands: rate.bands, trainingKcal: training, movementKcal: movement, comparison: mode,
                      comparisonPoints: points(compare), comparisonCaption: caption, comparisonUnavailable: unavailable)
    }

    static func summary(_ s: DailyEnergySummary) -> Summary {
        Summary(day: s.day, total: s.totalBurnedSoFar, active: s.activeBurnedSoFar, basal: s.basalBurnedSoFar,
                bmr24h: s.estimatedBMR24h, projectedLow: s.projectedRangeKcal?.lowerBound,
                projectedHigh: s.projectedRangeKcal?.upperBound, source: s.source.rawValue, sourceLabel: sourceLabel(s.source),
                confidence: "\(s.confidence)", confidenceLabel: confidenceLabel(s.confidence), compactLine: compactLine(s))
    }

    /// `EnergyProvenance.sourceLabel`.
    static func sourceLabel(_ source: EnergySource) -> String {
        switch source {
        case .appleSplit:     return String(localized: "Apple Health (active + basal)")
        case .strapWornTime:  return String(localized: "Strap, worn-time estimate")
        case .mixed:          return String(localized: "Several sources")
        case .stepsEstimate:  return String(localized: "Steps estimate")
        case .loggedActivity: return String(localized: "Logged sessions + steps")
        case .profileOnly:    return String(localized: "Profile only")
        }
    }

    /// `EnergyProvenance.confidenceLabel`.
    static func confidenceLabel(_ confidence: ScoreConfidence) -> String {
        switch confidence {
        case .solid:       return String(localized: "High")
        case .building:    return String(localized: "Partial")
        case .calibrating: return String(localized: "Low")
        }
    }

    /// `EnergyProvenance.compactLine`: "WHOOP · 87 % captured · ±8 %", nil without a coverage figure.
    static func compactLine(_ s: DailyEnergySummary) -> String? {
        guard let energy = s.coverage.energy else { return nil }
        let source: String
        switch s.source {
        case .strapWornTime: source = "WHOOP"
        case .appleSplit:    source = "Apple Health"
        case .mixed, .stepsEstimate, .loggedActivity, .profileOnly: return nil
        }
        var line = "\(source) · \(Int((energy * 100).rounded())) % \(String(localized: "captured"))"
        if let uncertainty = s.uncertaintyFraction {
            line += " · ±\(Int((uncertainty * 100).rounded())) %"
        }
        return line
    }

    static func previousDay(_ day: String) -> String? {
        guard let date = WeightSeries.date(forDay: day),
              let previous = Calendar.current.date(byAdding: .day, value: -1, to: date) else { return nil }
        return StoreReader.localDayKey(previous)
    }

    /// `Repository.energyDayRate`: the stored five-minute buckets (active scaled by an active Watch calibration),
    /// the sessions inside the day (cross-source twins once) and the share of active energy inside them.
    static func dayRate(reader: StoreReader, settings: CoreGoals.Settings, day: String)
        async -> (points: [EnergyBurnRate.Point], bands: [Band], fraction: Double?) {
        let store = reader.store
        guard let noon = WeightSeries.date(forDay: day) else { return ([], [], nil) }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: noon)
        let startTs = Int(start.timeIntervalSince1970)
        let endTs = Int((calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)).timeIntervalSince1970)
        let rows = (try? await store.whoopEnergyBuckets(deviceId: reader.activeDeviceId, day: day)) ?? []
        let activeFactor = await calibrationFactor(store: store, deviceId: reader.activeDeviceId,
                                                   optedIn: settings.energyCalibrationEnabled)
        let slices = rows.map {
            EnergyBurnRate.Slice(startSeconds: Double($0.bucketStart - startTs), durationSeconds: Double($0.durationSeconds),
                                 basalKcal: $0.basalKcal, activeKcal: $0.activeKcal * activeFactor)
        }
        let sessions = WorkoutSource.dedupCrossSource(
            await reader.rawWorkoutRows(from: startTs - 2 * 86_400, to: endTs,
                                        dismissedDetectedSpans: settings.dismissedWorkoutSpans))
            .filter { $0.endTs > startTs && $0.startTs < endTs }
            .sorted { $0.startTs < $1.startTs }
        let bands = sessions.map { Band(start: Double(max($0.startTs, startTs) - startTs),
                                        end: Double(min($0.endTs, endTs) - startTs), sport: $0.sport) }
        let split = EnergyBurnRate.activeSplit(slices: slices,
                                               training: bands.map { .init(startSeconds: $0.start, endSeconds: $0.end) })
        let total = split.training + split.movement
        return (EnergyBurnRate.measured(slices: slices), bands, total > 0 ? split.training / total : nil)
    }

    /// The Watch reference multiplier on active energy, applied only while it is active (`energyCalibrationState`).
    static func calibrationFactor(store: WhoopStore, deviceId: String, optedIn: Bool) async -> Double {
        guard optedIn, let row = try? await store.energyCalibrationModel(deviceId: deviceId),
              row.enabled, row.modelVersion == EnergyCalibrationFit.modelVersion else { return 1 }
        return row.factor
    }

    /// `Repository.energyReferenceRate`: the median hourly curve over the `windowDays` days before `day`, from the
    /// days of this model generation that were measured enough to qualify.
    static func referenceRate(reader: StoreReader, profile: UserProfile, before day: String, windowDays: Int)
        async -> EnergyBurnRate.Reference? {
        let store = reader.store
        guard let noon = WeightSeries.date(forDay: day),
              let previous = Calendar.current.date(byAdding: .day, value: -1, to: noon),
              let first = Calendar.current.date(byAdding: .day, value: -windowDays, to: noon) else { return nil }
        let from = StoreReader.localDayKey(first), to = StoreReader.localDayKey(previous)
        let hours = (try? await store.whoopEnergyHours(deviceId: reader.activeDeviceId, from: from, to: to)) ?? []
        let daily = (try? await store.whoopDailyEnergy(deviceId: reader.activeDeviceId, from: from, to: to)) ?? []
        let eligible = Set(daily.filter {
            EnergyBurnRate.dayQualifies(modelVersion: $0.modelVersion, representedSeconds: $0.representedSeconds)
        }.map(\.day))
        guard !eligible.isEmpty else { return nil }
        var byDay: [String: [Double]] = [:]
        for row in hours where eligible.contains(row.day) && (0...23).contains(row.hour) {
            byDay[row.day, default: [Double](repeating: 0, count: 24)][row.hour] += row.activeKcal
        }
        // `bodyFatResolver`: the day's body fat for a formula that needs it, none otherwise.
        var dayProfile = profile
        dayProfile.bodyFatPercent = nil
        if profile.basalFormula.needsBodyFat {
            let metrics = await BodyMetricsReader.read(reader: reader, activeDeviceId: reader.activeDeviceId, days: 4_000)
            dayProfile.bodyFatPercent = metrics.asOf("body_fat", day: day)?.value
        }
        return EnergyBurnRate.reference(
            days: byDay.sorted { $0.key < $1.key }.map { .init(day: $0.key, activeKcalByHour: $0.value) },
            windowDays: windowDays, basalKcalPerDay: Calories.bmrKcalPerDay(profile: dayProfile))
    }
}
