import SwiftUI
import StrandDesign

/// Trends' "What changed": every key measure's mean over the last 7, 30 or 90 days against the same span
/// before it, ranked by how far it moved and coloured by whether that move is good for the wearer. The rest
/// of the page draws each measure on its own; this is the one place that says what moved overall.
struct TrendsChangeSummary: View {
    @EnvironmentObject private var repo: Repository
    @State private var window = 7
    @State private var rows: [Row] = []
    @State private var loaded = false

    /// A measure, where it is read from, and which way is good (nil: neither way is better).
    private struct Measure {
        let key: String
        let source: String
        let higherIsBetter: Bool?
    }

    struct Row: Identifiable, Equatable {
        let id: String
        let title: String
        let icon: String
        /// The daily values of both spans, oldest first; `split` is the first index of the recent span.
        let values: [Double]
        let split: Int
        let beforeMean: Double
        let nowMean: Double
        let before: String
        let now: String
        /// Relative change, -1...+inf.
        let change: Double
        let verdict: Verdict
        /// What the move means for the wearer, in a coach's words.
        let meaning: String
    }

    enum Verdict { case better, worse, steady, neutral }

    private static let measures: [Measure] = {
        let strap = Repository.whoopSource
        return [
            Measure(key: "recovery", source: strap, higherIsBetter: true),
            Measure(key: "hrv", source: strap, higherIsBetter: true),
            Measure(key: "rhr", source: strap, higherIsBetter: false),
            Measure(key: "sleep_total_min", source: strap, higherIsBetter: true),
            Measure(key: "sleep_consistency", source: strap, higherIsBetter: true),
            Measure(key: "resp_rate", source: strap, higherIsBetter: nil),
            Measure(key: "stress", source: strap, higherIsBetter: false),
            Measure(key: "steps", source: strap, higherIsBetter: true),
            Measure(key: "strain", source: strap, higherIsBetter: nil),
            Measure(key: "weight", source: "noop-weight", higherIsBetter: nil),
        ]
    }()

    /// What a move of this measure means, by its verdict and direction. Plain words, no diagnosis:
    /// the sentence says what such a change usually goes with and what helps, never what the wearer has.
    private static func meaning(key: String, verdict: Verdict, up: Bool) -> String {
        if verdict == .steady {
            return String(localized: "No real change. Steady is good when the level is where you want it.")
        }
        let better = verdict == .better
        switch key {
        case "recovery":
            return better ? String(localized: "Your body bounced back better on most mornings. Keep the habits that got you here.")
                          : String(localized: "Your body recovered less on most mornings. An easier day or an earlier night helps it catch up.")
        case "hrv":
            return better ? String(localized: "Higher variability usually means your nervous system is relaxed and recovering well.")
                          : String(localized: "Lower variability often follows hard training, short sleep, stress or a cold coming on.")
        case "rhr":
            return better ? String(localized: "A lower resting pulse is a classic sign of growing fitness and good recovery.")
                          : String(localized: "A rising resting pulse can mean fatigue, stress, alcohol or a cold. Worth an easier day.")
        case "sleep_total_min":
            return better ? String(localized: "More sleep gives your body more time to repair. It shows up in your scores.")
                          : String(localized: "Shorter nights add up. Even 30 minutes earlier to bed makes a difference.")
        case "sleep_consistency":
            return better ? String(localized: "Regular bed and wake times keep your body clock steady and your sleep deeper.")
                          : String(localized: "Your sleep times drifted. A fixed wake time is the easiest anchor.")
        case "stress":
            return better ? String(localized: "Calmer days: your heart spent less time under strain outside of training.")
                          : String(localized: "More strain in daily life. Short breaks and slow breathing help your body settle.")
        case "steps":
            return better ? String(localized: "More everyday movement is one of the strongest levers for long-term health.")
                          : String(localized: "Fewer steps than before. A short walk after meals is an easy way back.")
        case "strain":
            return up ? String(localized: "You trained more than before. Make sure your recovery keeps pace.")
                      : String(localized: "You trained less than before. Fine for a rest week, otherwise a nudge to move.")
        case "resp_rate":
            return String(localized: "Breathing rate at night usually stays very stable. A clear, lasting rise can be an early sign of illness.")
        default:
            return String(localized: "Day-to-day weight is mostly water. The trend over several weeks is what counts.")
        }
    }

    /// Moves smaller than this read as steady: day-to-day noise, not a change.
    private static let deadband = 0.02

    var body: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("What changed").font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
                    Spacer(minLength: 8)
                    Picker("Range", selection: $window) {
                        Text("\(7) days").tag(7)
                        Text("\(30) days").tag(30)
                        Text("\(90) days").tag(90)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
                Text("Compared with the \(window) days before")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                if !rows.isEmpty {
                    headline
                    tally
                }
                if rows.isEmpty, loaded {
                    Text("No data yet").font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                } else {
                    VStack(spacing: 12) {
                        // Every measure that moved gets its own card with the meaning written out; the ones
                        // that held still share one quiet block at the end.
                        ForEach(rows.filter { $0.verdict != .steady }) { row in insightCard(row) }
                        let steady = rows.filter { $0.verdict == .steady }
                        if !steady.isEmpty { steadyBlock(steady) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: "\(repo.refreshSeq)-\(window)") { await load() }
    }

    /// The coach's one-line read of the span: which way it leaned and what moved most.
    private var headline: some View {
        let better = rows.filter { $0.verdict == .better }
        let worse = rows.filter { $0.verdict == .worse }
        let (title, detail, symbol, tint): (String, String, String, Color) = {
            if better.count > worse.count, let top = better.first {
                return (String(localized: "Strong stretch"), String(localized: "\(top.title) improved the most."),
                        "flame.fill", StrandPalette.chargeColor)
            }
            if worse.count > better.count, let top = worse.first {
                return (String(localized: "Tougher stretch"), String(localized: "\(top.title) needs the most attention."),
                        "leaf.fill", StrandPalette.effortColor)
            }
            if let top = better.first ?? worse.first {
                return (String(localized: "Mixed picture"), String(localized: "\(top.title) moved the most."),
                        "scalemass.fill", StrandPalette.accent)
            }
            return (String(localized: "Steady"), String(localized: "No real change. Steady is good when the level is where you want it."),
                    "equal.circle.fill", StrandPalette.textSecondary)
        }()
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Circle().fill(LinearGradient(colors: [tint.opacity(0.75), tint], startPoint: .top, endPoint: .bottom)))
                .shadow(color: tint.opacity(0.35), radius: 6, y: 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                Text(verbatim: detail).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(tint.opacity(0.08)))
        .accessibilityElement(children: .combine)
    }

    /// How many measures moved which way, as three counts in their colours.
    private var tally: some View {
        let better = rows.filter { $0.verdict == .better }.count
        let worse = rows.filter { $0.verdict == .worse }.count
        let steady = rows.count - better - worse
        let total = max(1, rows.count)
        return VStack(alignment: .leading, spacing: 10) {
            // The share of each verdict as one bar: the page's answer at a glance before any row.
            GeometryReader { geo in
                let gap: CGFloat = 3
                let usable = geo.size.width - gap * 2
                HStack(spacing: gap) {
                    ForEach(Array([(better, StrandPalette.chargeColor), (worse, StrandPalette.effortColor),
                                   (steady, StrandPalette.textTertiary.opacity(0.45))].enumerated()), id: \.offset) { _, part in
                        if part.0 > 0 {
                            Capsule().fill(part.1)
                                .frame(width: max(8, usable * CGFloat(part.0) / CGFloat(total)))
                        }
                    }
                }
            }
            .frame(height: 10)
            .accessibilityHidden(true)
            HStack(spacing: 8) {
                chip(count: better, word: Text("better"), color: StrandPalette.chargeColor)
                chip(count: worse, word: Text("worse"), color: StrandPalette.effortColor)
                chip(count: steady, word: Text("steady"), color: StrandPalette.textSecondary)
            }
        }
    }

    private func chip(count: Int, word: Text, color: Color) -> some View {
        HStack(spacing: 4) {
            Text(verbatim: "\(count)").font(StrandFont.headline.monospacedDigit())
            word.font(StrandFont.caption)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(color.opacity(0.12)))
        .accessibilityElement(children: .combine)
    }

    /// One measure that moved: its name and change large, its two spans as a wide line, and what the move
    /// means for the wearer as a short paragraph, always visible.
    private func insightCard(_ row: Row) -> some View {
        let tint = color(row.verdict)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: row.icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(tint.opacity(0.16)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: row.title).font(Font.system(.title3, design: .rounded).weight(.bold))
                        .foregroundStyle(StrandPalette.textPrimary).lineLimit(1).minimumScaleFactor(0.75)
                    Text(verbatim: "\(row.before) → \(row.now)").font(StrandFont.subhead.monospacedDigit())
                        .foregroundStyle(StrandPalette.textSecondary).lineLimit(1).minimumScaleFactor(0.8)
                }
                Spacer(minLength: 8)
                HStack(spacing: 3) {
                    Image(systemName: row.change > 0 ? "arrow.up" : "arrow.down").font(.system(size: 15, weight: .heavy))
                    Text(verbatim: "\(abs(Int((row.change * 100).rounded()))) %").font(StrandFont.rounded(26, weight: .bold).monospacedDigit())
                }
                .foregroundStyle(tint)
                .fixedSize()
            }
            ChangeSpark(values: row.values, split: row.split, beforeMean: row.beforeMean,
                        nowMean: row.nowMean, tint: tint)
                .frame(height: 56)
                .accessibilityHidden(true)
            Text(verbatim: row.meaning).font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(tint.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(tint.opacity(0.16), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    /// The measures that held still, one line each, under one heading.
    private func steadyBlock(_ steady: [Row]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "equal.circle.fill").foregroundStyle(StrandPalette.textSecondary)
                Text("Holding steady").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
            }
            ForEach(steady) { row in
                HStack(spacing: 10) {
                    Image(systemName: row.icon).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(StrandPalette.textSecondary).frame(width: 22)
                    Text(verbatim: row.title).font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(verbatim: row.now).font(StrandFont.subhead.monospacedDigit()).foregroundStyle(StrandPalette.textSecondary)
                }
                .accessibilityElement(children: .combine)
            }
            Text("No real change. Steady is good when the level is where you want it.")
                .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(StrandPalette.textPrimary.opacity(0.04)))
    }

    private func color(_ verdict: Verdict) -> Color {
        switch verdict {
        case .better: return StrandPalette.chargeColor
        case .worse: return StrandPalette.effortColor
        case .steady, .neutral: return StrandPalette.textSecondary
        }
    }

    private func percent(_ change: Double) -> String {
        let value = Int((change * 100).rounded())
        if value == 0 { return "0 %" }
        return (value > 0 ? "+" : "−") + "\(abs(value)) %"
    }

    // MARK: - Data

    private func load() async {
        let span = window
        var out: [Row] = []
        for m in Self.measures {
            guard let d = MetricCatalog.metric(key: m.key, source: m.source) else { continue }
            let series = await repo.exploreSeries(key: m.key, source: m.source, days: span * 2 + 1)
            guard let row = Self.row(series, span: span, measure: m, metric: d) else { continue }
            out.append(row)
        }
        rows = out.sorted { abs($0.change) > abs($1.change) }
        loaded = true
    }

    private static func row(_ series: [(day: String, value: Double)], span: Int, measure: Measure,
                            metric: MetricDescriptor) -> Row? {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let cut = cal.date(byAdding: .day, value: -span, to: today),
              let start = cal.date(byAdding: .day, value: -2 * span, to: today) else { return nil }
        let key = { (d: Date) in Repository.localDayKey(d) }
        let cutKey = key(cut), startKey = key(start)
        let recent = series.filter { $0.day > cutKey }.map(\.value)
        let earlier = series.filter { $0.day > startKey && $0.day <= cutKey }.map(\.value)
        // A third of each span, at least two days: a mean of one reading is that reading.
        let minimum = max(2, span / 3)
        guard recent.count >= minimum, earlier.count >= minimum else { return nil }
        let ordered = series.filter { $0.day > startKey }.sorted { $0.day < $1.day }
        let split = ordered.firstIndex { $0.day > cutKey } ?? ordered.count
        let now = recent.reduce(0, +) / Double(recent.count)
        let before = earlier.reduce(0, +) / Double(earlier.count)
        guard before != 0 else { return nil }
        let change = (now - before) / abs(before)
        let verdict: Verdict
        if abs(change) < deadband { verdict = .steady }
        else if let up = measure.higherIsBetter { verdict = (change > 0) == up ? .better : .worse }
        else { verdict = .neutral }
        return Row(id: metric.id, title: metric.title, icon: metric.icon, values: ordered.map(\.value), split: split,
                   beforeMean: before, nowMean: now, before: format(before, metric),
                   now: format(now, metric), change: change, verdict: verdict,
                   meaning: meaning(key: measure.key, verdict: verdict, up: change > 0))
    }

    /// Minutes as hours and minutes, everything else with the catalog's precision and unit.
    private static func format(_ value: Double, _ metric: MetricDescriptor) -> String {
        if metric.unit == "min" {
            let total = Int(value.rounded())
            return "\(total / 60):\(String(format: "%02d", total % 60)) h"
        }
        let decimals = metric.unit == "/100" ? 0 : metric.decimals
        let number = value.formatted(.number.precision(.fractionLength(decimals)).locale(AppLanguage.activeLocale))
        switch metric.unit {
        case "", "/100", "/3", "/5": return number
        default: return "\(number) \(metric.unit)"
        }
    }
}

/// One measure's two spans as a small line: the earlier span quiet, the recent span in the verdict colour,
/// each with its mean as a short dashed level, so the step between them is what the eye lands on.
private struct ChangeSpark: View {
    let values: [Double]
    let split: Int
    let beforeMean: Double
    let nowMean: Double
    let tint: Color

    var body: some View {
        Canvas { context, size in
            guard values.count > 1 else { return }
            let lo = min(values.min() ?? 0, beforeMean, nowMean)
            let hi = max(values.max() ?? 1, beforeMean, nowMean)
            let spread = max(hi - lo, abs(hi) * 0.02, 0.0001)
            let step = size.width / CGFloat(values.count - 1)
            func point(_ i: Int, _ v: Double) -> CGPoint {
                CGPoint(x: CGFloat(i) * step, y: size.height - 3 - CGFloat((v - lo) / spread) * (size.height - 6))
            }
            let cut = max(1, min(split, values.count - 1))
            var earlier = Path(), recent = Path()
            for i in 0...cut { i == 0 ? earlier.move(to: point(i, values[i])) : earlier.addLine(to: point(i, values[i])) }
            for i in cut..<values.count { i == cut ? recent.move(to: point(i, values[i])) : recent.addLine(to: point(i, values[i])) }
            var fill = recent
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.addLine(to: CGPoint(x: CGFloat(cut) * step, y: size.height))
            fill.closeSubpath()
            context.fill(fill, with: .linearGradient(Gradient(colors: [tint.opacity(0.28), tint.opacity(0)]),
                                                     startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            let quiet = StrandPalette.textTertiary.opacity(0.6)
            context.stroke(earlier, with: .color(quiet), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            context.stroke(recent, with: .color(tint), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            let dash = StrokeStyle(lineWidth: 1, dash: [2, 2])
            var beforeLevel = Path()
            beforeLevel.move(to: CGPoint(x: 0, y: point(0, beforeMean).y))
            beforeLevel.addLine(to: CGPoint(x: CGFloat(cut) * step, y: point(0, beforeMean).y))
            context.stroke(beforeLevel, with: .color(quiet), style: dash)
            var nowLevel = Path()
            nowLevel.move(to: CGPoint(x: CGFloat(cut) * step, y: point(0, nowMean).y))
            nowLevel.addLine(to: CGPoint(x: size.width, y: point(0, nowMean).y))
            context.stroke(nowLevel, with: .color(tint.opacity(0.7)), style: dash)
            let last = point(values.count - 1, values[values.count - 1])
            context.fill(Path(ellipseIn: CGRect(x: last.x - 2.5, y: last.y - 2.5, width: 5, height: 5)), with: .color(tint))
        }
    }
}
