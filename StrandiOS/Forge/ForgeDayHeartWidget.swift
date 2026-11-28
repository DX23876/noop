#if os(iOS)
import SwiftUI
import StrandDesign
import WhoopStore

/// Today's heart rate across the whole day as a Today widget: the strap's banked 5-minute averages from
/// midnight, last night's sleep band with its duration, a sport glyph at each workout, and Min/Avg/Max.
/// Adopted from DX23876/noop#58 by @sondrealf.
///
/// The wide Live heart rate card answers "what is my pulse now": while a strap streams it draws the last
/// ninety seconds, so its curve and Min/Avg/Max describe a minute and a half. This card answers "how has my
/// day gone", which the classic Today used to draw and the new design had no tile for. It is the Deep
/// Timeline's chart (`OverviewHRChart`, fed the same sleep and workout layers) at a glance, and the card
/// opens the Deep Timeline itself, as the stress card beside it opens Stress.
///
/// The header names the card as its neighbour "Stress through the day" does, in words rather than in the
/// bucket size. It shows a figure only while a strap streams one, marked as now: a banked average from
/// hours ago, unlabelled, would read as the current pulse.
struct ForgeDayHeartWidget: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var live: LiveState
    @State private var buckets: [HRBucket] = []
    @State private var sleepSpan: OverviewHRChart.SleepSpan?
    @State private var workoutSpans: [OverviewHRChart.WorkoutSpan] = []

    /// What a reload depends on: fresh data, and the day itself, so the card starts over at midnight.
    private struct ReloadKey: Equatable {
        let refresh: Int
        let dayStart: Date
    }

    private var dayBounds: ClosedRange<Date> {
        let start = Calendar.current.startOfDay(for: Date())
        return start...(Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400))
    }

    private var points: [TrendPoint] {
        buckets.map { TrendPoint(date: Date(timeIntervalSince1970: TimeInterval($0.ts)), value: $0.bpm) }
    }

    /// The live pulse while a strap streams one; nothing otherwise.
    private var liveBpm: Int? {
        guard live.connected, let hr = live.heartRate, hr > 0 else { return nil }
        return hr
    }

    var body: some View {
        NavigationLink(value: TabRoute.fullDayChart) {
            VStack(alignment: .leading, spacing: 10) {
                header
                if points.count >= 2 {
                    let values = points.map(\.value)
                    let avg = values.reduce(0, +) / Double(values.count)
                    OverviewHRChart(points: points, sleep: sleepSpan, workouts: workoutSpans,
                                    valueRange: Self.valueRange(values), xRange: dayBounds,
                                    height: 170, showsHover: false,
                                    dateFormat: { $0.formatted(.dateTime.hour().minute().locale(AppLanguage.activeLocale)) })
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text("Heart rate through the day"))
                        .accessibilityValue(Text(verbatim: [
                            "\(String(localized: "Min")) \(Self.whole(values.min()))",
                            "\(String(localized: "Avg")) \(Self.whole(avg))",
                            "\(String(localized: "Max")) \(Self.whole(values.max()))",
                        ].joined(separator: ", ")))
                    HStack {
                        stat(String(localized: "Min"), values.min())
                        Spacer()
                        stat(String(localized: "Avg"), avg)
                        Spacer()
                        stat(String(localized: "Max"), values.max())
                    }
                } else {
                    // Says when the curve comes, in one line under the title: an empty card that only said
                    // "nothing stored" held a whole slot and left the next step to guessing (critique 2026-11-28).
                    Text("No heart rate from today yet. It appears once your strap syncs.")
                        .font(ForgeFont.caption)
                        .foregroundStyle(ForgeColor.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .forgeCard(radius: ForgeRadius.card, padding: 16)
        }
        .buttonStyle(LiquidPressStyle())
        .accessibilityHint(Text("Opens the full-day heart rate timeline"))
        .task(id: ReloadKey(refresh: repo.refreshSeq, dayStart: dayBounds.lowerBound)) { await reload() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "heart.fill").font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(StrandPalette.metricRose)
            Text("Heart rate through the day").font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(ForgeColor.text)
            Spacer(minLength: 0)
            if let bpm = liveBpm {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("Now").font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                    Text("\(bpm)").font(ForgeFont.figure(17)).foregroundStyle(StrandPalette.metricRose)
                        .contentTransition(.numericText())
                    Text("bpm").font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                }
            }
        }
    }

    private func stat(_ label: String, _ v: Double?) -> some View {
        HStack(spacing: 5) {
            Text(label).font(ForgeFont.caption).foregroundStyle(ForgeColor.tertiary)
            Text(Self.whole(v)).font(ForgeFont.figure(15)).foregroundStyle(ForgeColor.secondary)
        }
    }

    private static func whole(_ v: Double?) -> String { v.map { String(Int($0.rounded())) } ?? "–" }

    /// Same reads and selection as the Deep Timeline's annotations (`FullDayChartView.reloadAnnotations`):
    /// on-device and imported sleeps, the longest one overlapping today as the night, never a nap; the
    /// band starts at the effective onset so a hand-corrected bedtime shows here as it does on Sleep.
    private func reload() async {
        let day = dayBounds
        let now = Date()
        let fetched = await repo.hrBuckets(from: Int(day.lowerBound.timeIntervalSince1970),
                                           to: Int(now.timeIntervalSince1970), bucketSeconds: 300)
        let sleeps: [OverviewHRChart.SleepSpan] = await repo.allSleepSessions(days: 2).map { s in
            .init(start: Date(timeIntervalSince1970: TimeInterval(s.effectiveStartTs)),
                  end: Date(timeIntervalSince1970: TimeInterval(s.endTs)),
                  label: Self.hoursMinutes(s.endTs - s.effectiveStartTs))
        }
        let workouts: [OverviewHRChart.WorkoutSpan] = await repo.workoutRows(days: 2).map { w in
            .init(start: Date(timeIntervalSince1970: TimeInterval(w.startTs)),
                  end: Date(timeIntervalSince1970: TimeInterval(w.endTs)),
                  symbol: sportSymbol(w.sport))
        }
        guard !Task.isCancelled else { return }
        buckets = fetched
        sleepSpan = OverviewHRChart.mainSleep(sleeps, overlapping: day)
        workoutSpans = OverviewHRChart.workouts(workouts, overlapping: day)
    }

    /// Whole tens around the day's range, so a resting day and a race day both fill the card.
    static func valueRange(_ values: [Double]) -> ClosedRange<Double> {
        guard let lo = values.min(), let hi = values.max() else { return 40...120 }
        let floor = max(30, ((lo - 5) / 10).rounded(.down) * 10)
        let ceil = max(floor + 30, ((hi + 5) / 10).rounded(.up) * 10)
        return floor...ceil
    }

    private static func hoursMinutes(_ seconds: Int) -> String {
        let h = max(0, seconds) / 3600, m = (max(0, seconds) % 3600) / 60
        return "\(h):\(String(format: "%02d", m))"
    }
}
#endif
