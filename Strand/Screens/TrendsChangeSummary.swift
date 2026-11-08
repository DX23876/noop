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
        /// The catalog key, for the measure's picture and colour.
        let key: String
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
        // Apple's grouping: the summary is one card, every measure that moved its own white card under it,
        // never a card inside a card.
        VStack(alignment: .leading, spacing: 12) {
            NoopCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("What changed").font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
                            Text("Compared with the \(window) days before")
                                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                        }
                        Spacer(minLength: 8)
                        Picker("Range", selection: $window) {
                            Text("\(7) days").tag(7)
                            Text("\(30) days").tag(30)
                            Text("\(90) days").tag(90)
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }
                    if !rows.isEmpty {
                        headline
                        tally
                    } else if loaded {
                        Text("No data yet").font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(rows.filter { $0.verdict != .steady }) { row in insightCard(row) }
            let steady = rows.filter { $0.verdict == .steady }
            if !steady.isEmpty { steadyBlock(steady) }
        }
        .task(id: "\(repo.refreshSeq)-\(window)") { await load() }
    }

    /// The span in one large line, the measure that moved most named under it.
    private var headline: some View {
        let better = rows.filter { $0.verdict == .better }
        let worse = rows.filter { $0.verdict == .worse }
        let (title, detail): (String, String) = {
            if better.count > worse.count, let top = better.first {
                return (String(localized: "Strong stretch"), String(localized: "\(top.title) improved the most."))
            }
            if worse.count > better.count, let top = worse.first {
                return (String(localized: "Tougher stretch"), String(localized: "\(top.title) needs the most attention."))
            }
            if let top = better.first ?? worse.first {
                return (String(localized: "Mixed picture"), String(localized: "\(top.title) moved the most."))
            }
            return (String(localized: "Steady"), String(localized: "No real change. Steady is good when the level is where you want it."))
        }()
        return VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: title).font(StrandFont.title1).foregroundStyle(StrandPalette.textPrimary)
            Text(verbatim: detail).font(StrandFont.body).foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
    }

    /// How many measures moved which way: one bar, then the counts as a dotted legend.
    private var tally: some View {
        let better = rows.filter { $0.verdict == .better }.count
        let worse = rows.filter { $0.verdict == .worse }.count
        let steady = rows.count - better - worse
        let total = max(1, rows.count)
        return VStack(alignment: .leading, spacing: 12) {
            GeometryReader { geo in
                let gap: CGFloat = 2
                let usable = geo.size.width - gap * 2
                HStack(spacing: gap) {
                    ForEach(Array([(better, StrandPalette.chargeColor), (worse, StrandPalette.effortColor),
                                   (steady, StrandPalette.textTertiary.opacity(0.4))].enumerated()), id: \.offset) { _, part in
                        if part.0 > 0 {
                            Capsule().fill(part.1)
                                .frame(width: max(8, usable * CGFloat(part.0) / CGFloat(total)))
                        }
                    }
                }
            }
            .frame(height: 8)
            .accessibilityHidden(true)
            HStack(spacing: 20) {
                legend(count: better, word: Text("better"), color: StrandPalette.chargeColor)
                legend(count: worse, word: Text("worse"), color: StrandPalette.effortColor)
                legend(count: steady, word: Text("steady"), color: StrandPalette.textTertiary)
                Spacer(minLength: 0)
            }
        }
    }

    private func legend(count: Int, word: Text, color: Color) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(verbatim: "\(count)").font(StrandFont.subhead.weight(.semibold).monospacedDigit())
                .foregroundStyle(StrandPalette.textPrimary)
            word.font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    /// Apple Health's category mark: the measure's symbol in white on a small square in its colour.
    static func categoryMark(_ symbol: String, tint: Color, size: CGFloat = 32) -> some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).fill(tint))
            .accessibilityHidden(true)
    }

    /// One measure that moved, as Apple writes a data card: its mark and name in the measure's colour, the
    /// change as the large figure in plain text (a coloured figure would read as a verdict), the verdict on a small badge, one line on what it means.
    private func insightCard(_ row: Row) -> some View {
        let identity = TrendIllustration.color(row.key)
        let verdict = row.verdict == .neutral ? StrandPalette.textSecondary : color(row.verdict)
        return NoopCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Self.categoryMark(TrendIllustration.symbol(row.key, up: row.change > 0), tint: identity)
                    Text(verbatim: row.title).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(verbatim: "\(row.before) → \(row.now)")
                        .font(StrandFont.rounded(28, weight: .bold)).foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    HStack(spacing: 4) {
                        Image(systemName: row.change > 0 ? "arrow.up" : "arrow.down").font(.system(size: 11, weight: .bold))
                        Text(verbatim: "\(abs(Int((row.change * 100).rounded()))) %")
                        if row.verdict == .better { Text("better") }
                        if row.verdict == .worse { Text("worse") }
                    }
                    .font(StrandFont.subhead.weight(.semibold).monospacedDigit())
                    .foregroundStyle(verdict)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(verdict.opacity(0.12)))
                    .fixedSize()
                    Spacer(minLength: 0)
                }
                Text(verbatim: row.meaning).font(StrandFont.body).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    /// The measures that held still, one row each in a grouped card.
    private func steadyBlock(_ steady: [Row]) -> some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Holding steady").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                ForEach(Array(steady.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Divider().overlay(StrandPalette.hairline).padding(.leading, 40) }
                    HStack(spacing: 12) {
                        Self.categoryMark(TrendIllustration.symbol(row.key, up: false),
                                          tint: TrendIllustration.color(row.key), size: 28)
                        Text(verbatim: row.title).font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(verbatim: row.now).font(StrandFont.subhead.monospacedDigit()).foregroundStyle(StrandPalette.textSecondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
        return Row(id: metric.id, key: measure.key, title: metric.title, icon: metric.icon, values: ordered.map(\.value), split: split,
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

/// Each measure's picture: its symbol large on a glowing disc in the measure's own colour, with two small
/// motifs around it that say what the measure is about. Drawn, not a file, so it follows light and dark.
struct TrendIllustration: View {
    let key: String
    let up: Bool

    /// The measure's identity colour across Trends, so a tab carries more than two hues.
    static func color(_ key: String) -> Color {
        switch key {
        case "recovery": return StrandPalette.chargeColor
        case "hrv": return StrandPalette.metricPurple
        case "rhr": return StrandPalette.metricRose
        case "sleep_total_min": return StrandPalette.restColor
        case "sleep_consistency": return .indigo
        case "stress": return StrandPalette.metricCyan
        case "steps": return StrandPalette.metricAmber
        case "strain": return StrandPalette.effortColor
        case "resp_rate": return .teal
        default: return .pink
        }
    }

    /// The measure's main symbol, for its category mark.
    static func symbol(_ key: String, up: Bool) -> String { TrendIllustration(key: key, up: up).motif.main }

    private var motif: (main: String, a: String, b: String) {
        switch key {
        case "recovery": return ("bolt.heart.fill", "sparkle", "sun.max.fill")
        case "hrv": return ("waveform.path.ecg", "heart.fill", "sparkle")
        case "rhr": return ("heart.fill", "waveform.path.ecg", "sparkle")
        case "sleep_total_min": return ("moon.zzz.fill", "star.fill", "sparkle")
        case "sleep_consistency": return ("bed.double.fill", "alarm.fill", "star.fill")
        case "stress": return (up ? "cloud.bolt.fill" : "leaf.fill", "wind", "sparkle")
        case "steps": return ("figure.walk", "shoeprints.fill", "sun.max.fill")
        case "strain": return ("flame.fill", "bolt.fill", "sparkle")
        case "resp_rate": return ("lungs.fill", "wind", "sparkle")
        default: return ("scalemass.fill", "leaf.fill", "sparkle")
        }
    }

    var body: some View {
        CoachPicture(main: motif.main, accentA: motif.a, accentB: motif.b, tint: Self.color(key))
    }
}

/// The coach cards' picture: a symbol large on a glowing disc in a given colour, with two small motifs
/// around it, breathing gently. Drawn, not a file, so it follows light and dark and every size.
struct CoachPicture: View {
    let main: String
    let accentA: String
    let accentB: String
    let tint: Color
    @State private var lift = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            ZStack {
                // A faint halo, not a glow: Apple's symbols sit on colour, they do not shine.
                Circle().fill(tint.opacity(0.14)).blur(radius: side * 0.12).scaleEffect(0.95)
                Circle()
                    .fill(tint)
                    .frame(width: side * 0.78, height: side * 0.78)
                    .shadow(color: tint.opacity(0.22), radius: side * 0.05, y: side * 0.03)
                Image(systemName: main)
                    .font(.system(size: side * 0.34, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                    .offset(y: lift ? -2 : 1)
                Image(systemName: accentA)
                    // One icon style per level: every badge glyph filled, never a mix of outline and filled.
                    .symbolVariant(.fill)
                    .font(.system(size: side * 0.15, weight: .bold))
                    .foregroundStyle(tint)
                    .padding(side * 0.06)
                    .background(Circle().fill(StrandPalette.surfaceBase))
                    .shadow(color: tint.opacity(0.3), radius: 4, y: 2)
                    .offset(x: side * 0.33, y: -side * 0.30)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) { lift = true }
        }
    }
}

/// The three sizes a coach picture comes in, so the same picture never appears at a dozen near-equal sizes.
enum CoachPictureSize {
    /// Tiles, routines, devices.
    static let small: CGFloat = 56
    /// Page heads and banners.
    static let medium: CGFloat = 72
    /// Coach cards and empty states.
    static let large: CGFloat = 96
}
