import Foundation
import StrandAnalytics
import StrandCore

// HealthspanSnapshot.swift — fork feature "AgeLess": the one resolver every AgeLess screen reads, shared by the
// Apple app and the Android core (parity plan 2.3). It reads the stored window and 30-day inputs and runs every
// week through the engine, so no two readers can disagree.

/// The stored AgeLess series a host reads: Apple's `Repository`, the core's store reader on Android.
protocol HealthspanSeriesReading {
    /// The daily values of one computed series, oldest first; `days` nil for the whole history.
    func healthspanSeries(key: String, days: Int?) async -> [(day: String, value: Double)]
}

/// One week as the screens show it.
struct HealthspanWeek {
    let day: String
    let inputs: HealthspanEngine.Inputs
    let recentInputs: HealthspanEngine.Inputs?
    let result: HealthspanEngine.Result
    let pace: Double?
    let coveredDays: Int
    /// Where the week's VO₂max came from; nil without one.
    let vo2Source: HealthspanVO2.Source?
    /// What each input stands on (`HealthspanBasis.counts`; VO₂max: its readings). Empty for a week stored
    /// before AI-23 rebuilt it.
    var counts: [HealthspanEngine.Component: Int] = [:]
    /// The newest VO₂max reading behind the week, or the day an entered value was measured.
    var vo2Day: String? = nil
    /// The body-fat reading behind the week's lean mass.
    var bodyFatDay: String? = nil
    /// The least VO₂max the week's long walks and runs allow (`HealthspanVO2.enduranceFloor`); a plausibility
    /// bound, never the measure's value.
    var vo2Floor: Double? = nil

    var isProvisional: Bool { coveredDays < HealthspanWindow.ageWindowDays }

    /// What one measure stands on. The current week's window ends today, an earlier one on its Friday.
    func basis(_ c: HealthspanEngine.Component, today: String) -> HealthspanBasis.Line? {
        HealthspanBasis.line(c, count: counts[c], coveredDays: coveredDays, vo2Source: vo2Source,
                             latestDay: c == .vo2max ? vo2Day : c == .leanMass ? bodyFatDay : nil,
                             weekEnd: min(HealthspanWindow.dayKey(day, plus: 6), today))
    }
    /// The last 30 days run through the engine, for each measure's trend.
    var recentResult: HealthspanEngine.Result? { recentInputs.flatMap(HealthspanEngine.compute) }
    var levers: [HealthspanEngine.Lever] { HealthspanEngine.levers(inputs) }
}

/// Every stored week, oldest first, resolved once.
struct HealthspanSnapshot {
    let weeks: [HealthspanWeek]
    /// The day the snapshot was read, the one clock its notes are judged by.
    var today: String = StoreReader.localDayKey(Date())
    var latest: HealthspanWeek { weeks[weeks.count - 1] }

    /// A stored week's values as engine inputs: the one builder every reader of an AgeLess week uses. Nil when the
    /// week holds none.
    static func weekInputs(_ series: [HealthspanEngine.Component: [String: Double]], day: String, age: Int,
                           sex: HealthspanEngine.Sex) -> HealthspanEngine.Inputs? {
        var x = HealthspanEngine.Inputs(age: Double(age), sex: sex)
        var any = false
        for c in HealthspanEngine.Component.allCases {
            let v = series[c]?[day]
            x.set(c, v)
            any = any || v != nil
        }
        return any ? x : nil
    }

    /// The newest week's window inputs only, for a surface that prices one value against it (a goal's AgeLess
    /// line), without reading every stored week. Same builder and same gate as `load`, so it names the week the
    /// AgeLess screens show as the newest: the latest stored week whose inputs price. Should that week not price,
    /// the full snapshot decides, so the two readers still agree.
    @MainActor
    static func latestInputs(repo: any HealthspanSeriesReading, age: Int, sex: HealthspanEngine.Sex) async -> HealthspanEngine.Inputs? {
                guard let newest = await repo.healthspanSeries(key: DailyAnalysis.healthspanAgeKey, days: nil)
            .map(\.day).max() else { return nil }
        let daysBack = HealthspanSnapshot.date(newest).map { Int(Date().timeIntervalSince($0) / 86_400) } ?? 0
        var window: [HealthspanEngine.Component: [String: Double]] = [:]
        for c in HealthspanEngine.Component.allCases {
            window[c] = Dictionary(await repo.healthspanSeries(key: DailyAnalysis.healthspanInputKey(c), days: daysBack + 7).map { ($0.day, $0.value) },
                                   uniquingKeysWith: { _, b in b })
        }
        if let x = weekInputs(window, day: newest, age: age, sex: sex), HealthspanEngine.compute(x) != nil { return x }
        return await load(repo: repo, age: age, sex: sex)?.latest.inputs
    }

    @MainActor
    static func load(repo: any HealthspanSeriesReading, age: Int, sex: HealthspanEngine.Sex) async -> HealthspanSnapshot? {
                func byDay(_ key: String) async -> [String: Double] {
            Dictionary(await repo.healthspanSeries(key: key, days: nil).map { ($0.day, $0.value) },
                       uniquingKeysWith: { _, b in b })
        }
        let days = await repo.healthspanSeries(key: DailyAnalysis.healthspanAgeKey, days: nil).map(\.day)
        var window: [HealthspanEngine.Component: [String: Double]] = [:]
        var recent: [HealthspanEngine.Component: [String: Double]] = [:]
        for c in HealthspanEngine.Component.allCases {
            window[c] = await byDay(DailyAnalysis.healthspanInputKey(c))
            recent[c] = await byDay(DailyAnalysis.healthspanRecentInputKey(c))
        }
        let paces = await byDay(DailyAnalysis.healthspanPaceKey)
        let covered = await byDay(DailyAnalysis.healthspanCoveredDaysKey)
        let vo2Sources = await byDay(DailyAnalysis.healthspanVO2SourceKey)
        let vo2Days = await byDay(DailyAnalysis.healthspanVO2DayKey)
        let bodyFatDays = await byDay(DailyAnalysis.healthspanBodyFatDayKey)
        let vo2Floors = await byDay(DailyAnalysis.healthspanVO2FloorKey)
        var counts: [HealthspanEngine.Component: [String: Double]] = [:]
        for c in HealthspanEngine.Component.allCases {
            counts[c] = await byDay(DailyAnalysis.healthspanCountKey(c))
        }
        func inputs(_ series: [HealthspanEngine.Component: [String: Double]], _ day: String) -> HealthspanEngine.Inputs? {
            weekInputs(series, day: day, age: age, sex: sex)
        }
        let weeks = days.compactMap { day -> HealthspanWeek? in
            guard let x = inputs(window, day), let result = HealthspanEngine.compute(x) else { return nil }
            return HealthspanWeek(day: day, inputs: x, recentInputs: inputs(recent, day), result: result,
                                  pace: paces[day], coveredDays: Int(covered[day] ?? 0),
                                  vo2Source: vo2Sources[day].flatMap { HealthspanVO2.Source(rawValue: Int($0)) },
                                  counts: counts.compactMapValues { $0[day].map { Int($0) } },
                                  vo2Day: vo2Days[day].flatMap { HealthspanBasis.dayKey(number: $0) },
                                  bodyFatDay: bodyFatDays[day].flatMap { HealthspanBasis.dayKey(number: $0) },
                                  vo2Floor: vo2Floors[day])
        }
        return weeks.isEmpty ? nil : HealthspanSnapshot(weeks: weeks)
    }

    /// Why there is no week to show: what the last pass stored for its current week (AI-29). Nil when no pass
    /// stored one in the last two weeks, so a stale gap never speaks for today.
    @MainActor
    static func gap(repo: any HealthspanSeriesReading) async -> HealthspanWindow.Gap? {
                guard let nights = await repo.healthspanSeries(key: DailyAnalysis.healthspanGapNightsKey, days: 14).max(by: { $0.day < $1.day }) else { return nil }
        let mask = await repo.healthspanSeries(key: DailyAnalysis.healthspanGapMissingKey, days: 14)
            .first { $0.day == nights.day }?.value ?? 0
        return HealthspanWindow.Gap(nights: Int(nights.value), missingMask: mask)
    }
}


extension HealthspanSnapshot {
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    /// A stored day key as a local date.
    static func date(_ day: String) -> Date? { dayFormatter.date(from: day) }
}
