#if os(iOS)
import SwiftUI
import StrandDesign
import WhoopStore

/// Today's heart rate across the whole day as a Today widget: the strap's banked 5-minute averages from
/// midnight, last night's sleep band with its duration, a sport glyph at each workout, and Min/Avg/Max.
///
/// The wide Live heart rate card answers "what is my pulse now": while a strap streams it draws the last
/// ninety seconds, so its curve and Min/Avg/Max describe a minute and a half. This card answers "how has my
/// day gone", which the classic Today used to draw and the new design had no tile for. It is the Deep
/// Timeline's chart (`OverviewHRChart`, fed the same sleep and workout layers) at a glance, and the header
/// opens the Deep Timeline itself.
struct ForgeDayHeartWidget: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var live: LiveState
    @State private var buckets: [HRBucket] = []
    @State private var sleepSpan: OverviewHRChart.SleepSpan?
    @State private var workoutSpans: [OverviewHRChart.WorkoutSpan] = []

    private var dayBounds: ClosedRange<Date> {
        let start = Calendar.current.startOfDay(for: Date())
        return start...(Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400))
    }

    private var points: [TrendPoint] {
        buckets.map { TrendPoint(date: Date(timeIntervalSince1970: TimeInterval($0.ts)), value: $0.bpm) }
    }

    /// The live pulse while a strap streams one, otherwise the latest banked 5-minute average.
    private var headlineBpm: Int? {
        if live.connected, let hr = live.heartRate, hr > 0 { return hr }
        return buckets.last.map { Int($0.bpm.rounded()) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            NavigationLink(value: TabRoute.fullDayChart) {
                header.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the full-day heart rate timeline")

            if points.count >= 2 {
                OverviewHRChart(points: points, sleep: sleepSpan, workouts: workoutSpans,
                                valueRange: Self.valueRange(points.map(\.value)), xRange: dayBounds,
                                height: 170, showsHover: false,
                                dateFormat: { Self.timeFmt.string(from: $0) })
                let values = points.map(\.value)
                HStack {
                    stat(String(localized: "Min"), values.min())
                    Spacer()
                    stat(String(localized: "Avg"), values.reduce(0, +) / Double(values.count))
                    Spacer()
                    stat(String(localized: "Max"), values.max())
                }
            } else {
                Text("No heart rate stored for today yet")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 24)
            }
        }
        .forgeCard(radius: ForgeRadius.card, padding: 16)
        .task(id: repo.refreshSeq) { await reload() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Heart Rate").font(StrandFont.overline).tracking(1.6)
                    .foregroundStyle(StrandPalette.textSecondary)
                Text("5-minute average · since midnight").font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer()
            if let bpm = headlineBpm {
                (Text("\(bpm)").font(StrandFont.rounded(22)).monospacedDigit()
                    + Text(" bpm").font(StrandFont.caption))
                    .foregroundStyle(StrandPalette.metricRose)
                    .contentTransition(.numericText())
            }
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                .foregroundStyle(StrandPalette.accent)
        }
    }

    private func stat(_ label: String, _ v: Double?) -> some View {
        HStack(spacing: 5) {
            Text(label).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            Text(v.map { String(Int($0.rounded())) } ?? "–")
                .font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textSecondary)
        }
    }

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

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("HH:mm")
        return f
    }()
}
#endif
