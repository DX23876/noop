import SwiftUI
import Charts
import StrandAnalytics
import StrandDesign

// MARK: - Energy (Stufe 2) — one card, not six tiles
//
// The individual figures (basal, active, total, projection, maintenance) would make five more Key
// Metric tiles, and five tiles that only ever move together are five ways to say one thing. This is
// the one card, with everything else on the detail screen behind it.
//
// The card's job is to be HONEST about how much of the day was actually measured. `EnergyEngine`
// hands over a coverage figure and a confidence tier derived from data that already exists — a
// three-hour Apple Watch day lands near 12% and must not render like a fully measured one. That is
// why the caption is not decoration: it is the difference between a number and a guess.

struct EnergyCard: View {
    let summary: DailyEnergySummary

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        NoopCard(tint: StrandPalette.energyResting) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    Label("Energy", systemImage: "flame.fill")
                        .strandOverlineLabel(color: StrandPalette.energyHighlight)
                    Spacer(minLength: 8)
                    confidencePill
                }

                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 16) { energyMark; headline }
                } else {
                    HStack(spacing: 18) { energyMark; headline }
                }

                Divider().overlay(StrandPalette.hairline)
                statStrip

                if let note = qualityNote {
                    Label(note, systemImage: "info.circle")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var energyMark: some View {
        EnergyCompositionMark(restingKcal: summary.basalBurnedSoFar,
                              activeKcal: summary.activeBurnedSoFar,
                              hasTotal: summary.totalBurnedSoFar != nil)
            .frame(width: 104, height: 104)
            .accessibilityHidden(true)
    }

    private var headline: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(headlineTotal)
                .font(StrandFont.title1)
                .foregroundStyle(StrandPalette.textPrimary)
                .monospacedDigit()
                .minimumScaleFactor(0.72)
            Text("total burned so far")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
            if let range = summary.projectedRangeKcal {
                Text("Forecast range: \(forecastRange(range)) kcal")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var headlineTotal: String {
        EnergyDisplay.totalText(summary, includesUnit: true)
    }

    private var statStrip: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 10) { statItems }
            VStack(alignment: .leading, spacing: 10) { statItems }
        }
    }

    @ViewBuilder private var statItems: some View {
        EnergyStat(label: restingLabel, value: kcal(summary.basalBurnedSoFar ?? summary.estimatedBMR24h),
                   symbol: "bed.double.fill", color: StrandPalette.energyResting,
                   approximate: summary.basalBurnedSoFar == nil)
        EnergyStat(label: "Active", value: kcal(summary.activeBurnedSoFar),
                   symbol: "figure.run", color: StrandPalette.energyActive)
        EnergyStat(label: "Projected", value: kcal(summary.projectedTotalBurn),
                   symbol: "sun.max.fill", color: StrandPalette.energyHighlight, approximate: true)
    }

    private var restingLabel: LocalizedStringKey {
        summary.basalBurnedSoFar == nil ? "Basal / day" : "Resting"
    }

    @ViewBuilder private var confidencePill: some View {
        HStack(spacing: 5) {
            Circle().fill(confidenceColor).frame(width: 6, height: 6)
            Text(confidenceLabel)
        }
        .font(StrandFont.footnote)
        .foregroundStyle(StrandPalette.textSecondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(StrandPalette.surfaceInset, in: Capsule())
    }

    private var confidenceLabel: LocalizedStringKey {
        switch summary.confidence {
        case .solid: return "Measured"
        case .building: return "Partly estimated"
        case .calibrating: return "Estimated"
        }
    }

    private var confidenceColor: Color {
        switch summary.confidence {
        case .solid: return StrandPalette.statusPositive
        case .building: return StrandPalette.statusWarning
        case .calibrating: return StrandPalette.textTertiary
        }
    }

    /// What the card says about its own reliability. `nil` on a solidly measured day — a caption that
    /// appears on every day teaches people to stop reading it.
    private var qualityNote: LocalizedStringKey? {
        switch summary.source {
        case .profileOnly:
            return "No wearable data for today yet — this is your estimated basal rate, not a measurement."
        case .stepsEstimate:
            return "Estimated from steps: no device recorded energy today."
        case .appleSplit, .strapWornTime, .mixed:
            switch summary.confidence {
            case .solid:       return nil
            case .building:    return "Partly estimated — your device didn't cover the whole day."
            case .calibrating: return "Mostly estimated — very little of today was recorded."
            }
        }
    }

    private func kcal(_ value: Double?) -> String? {
        value.map { "\(Int($0.rounded()).formatted(.number.grouping(.automatic))) kcal" }
    }

    /// "2,400–2,900" — grouped per the reader's locale, joined with an en dash (the range dash).
    private func forecastRange(_ range: ClosedRange<Double>) -> String {
        let low = Int(range.lowerBound.rounded()).formatted(.number.grouping(.automatic))
        let high = Int(range.upperBound.rounded()).formatted(.number.grouping(.automatic))
        return "\(low)–\(high)"
    }

    private var accessibilitySummary: String {
        var parts = [String(localized: "Energy"), headlineTotal, String(localized: "total burned so far")]
        if let active = kcal(summary.activeBurnedSoFar) {
            parts.append("\(String(localized: "Active")): \(active)")
        }
        if let resting = kcal(summary.basalBurnedSoFar ?? summary.estimatedBMR24h) {
            parts.append("\(String(localized: "Resting")): \(resting)")
        }
        return parts.joined(separator: ", ")
    }
}

/// Shared presentation contract for every Today surface that shows the canonical daily total.
/// Keeping the approximation marker and rounding here prevents the compact Calories tile from
/// drifting back to Apple active energy or the legacy `activeKcalEst` value.
enum EnergyDisplay {
    static func totalText(_ summary: DailyEnergySummary?, includesUnit: Bool = false) -> String {
        guard let summary, let total = summary.totalBurnedSoFar,
              total.isFinite, total >= 0 else { return "—" }
        let number = Int(total.rounded()).formatted(.number.grouping(.automatic))
        let approximate = summary.source == .appleSplit ? number : "~\(number)"
        return includesUnit ? "\(approximate) kcal" : approximate
    }
}

struct EnergyCompositionMark: View {
    let restingKcal: Double?
    let activeKcal: Double?
    let hasTotal: Bool

    static func fractions(resting: Double?, active: Double?) -> (resting: Double, active: Double)? {
        let resting = max(0, resting ?? 0)
        let active = max(0, active ?? 0)
        let total = resting + active
        guard total > 0 else { return nil }
        return (resting / total, active / total)
    }

    private var fractions: (resting: Double, active: Double)? {
        Self.fractions(resting: restingKcal, active: activeKcal)
    }

    var body: some View {
        ZStack {
            Circle().stroke(StrandPalette.energyTrack, style: .init(lineWidth: 10, lineCap: .round))
            if hasTotal, let fractions {
                Circle()
                    .trim(from: 0, to: fractions.resting)
                    .stroke(StrandPalette.energyResting,
                            style: .init(lineWidth: 10, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
                if fractions.active > 0 {
                    Circle()
                        .trim(from: fractions.resting, to: 1)
                        .stroke(StrandPalette.energyActive,
                                style: .init(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
            }
            Circle()
                .fill(StrandPalette.energyHighlight.opacity(0.12))
                .frame(width: 62, height: 62)
            Image(systemName: "flame.fill")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(LinearGradient(gradient: StrandPalette.energyGradient,
                                                startPoint: .top, endPoint: .bottom))
        }
    }
}

private struct EnergyStat: View {
    let label: LocalizedStringKey
    let value: String?
    let symbol: String
    let color: Color
    var approximate = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 28, height: 28)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                Text(displayValue)
                    .font(StrandFont.captionNumber)
                    .foregroundStyle(value == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var displayValue: String {
        guard let value else { return "—" }
        return approximate ? "~\(value)" : value
    }
}

private extension Label where Title == Text, Icon == Image {
    func strandOverlineLabel(color: Color) -> some View {
        self
            .font(StrandFont.overline)
            .tracking(StrandFont.overlineTracking)
            .textCase(.uppercase)
            .foregroundStyle(color)
    }
}
// MARK: - Detail

/// The figures behind the card, plus where they came from. Progressive disclosure: the card answers
/// "how much?", this answers "how do you know?".
struct EnergyDetailView: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var profile: ProfileStore

    @State private var summaries: [DailyEnergySummary] = []
    @State private var loaded = false
    @State private var loading = false
    @State private var refreshingToday = false
    @State private var calibration = EnergyCalibrationViewState.off
    @State private var updatingCalibration = false
    @State private var adaptiveEstimate: AdaptiveExpenditureEstimate?
    @State private var timeline: [EnergyTimelinePoint] = []
    @State private var technicalDetailsExpanded = false

    private var today: DailyEnergySummary? {
        let key = Repository.localDayKey(Date())
        return summaries.last { $0.day == key }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                SectionHeader("Energy", overline: "Today")
                if !loaded {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading energy…")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else if let today {
                    EnergyCard(summary: today)
                    if refreshingToday {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Updating today's energy…")
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                    }
                    if !timeline.isEmpty { todayTimeline(summary: today) }
                } else {
                    emptyState
                }
                if !history.isEmpty { chart }
                if loaded, let adaptiveEstimate { adaptiveComparison(adaptiveEstimate) }
                if loaded, let today { technicalDetails(today) }
            }
            .padding(NoopMetrics.screenPadding)
        }
        .navigationTitle(Text("Energy"))
        .task { await loadIfNeeded() }
    }

    private func todayTimeline(summary: DailyEnergySummary) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Energy through today", trailing: String(localized: "cumulative"))
            NoopCard {
                Chart {
                    ForEach(timeline) { point in
                        AreaMark(x: .value("Time", point.timestamp),
                                 yStart: .value("Resting start", 0),
                                 yEnd: .value("Resting", point.basalKcal))
                            .foregroundStyle(StrandPalette.energyResting.opacity(0.16))
                        AreaMark(x: .value("Time", point.timestamp),
                                 yStart: .value("Active start", point.basalKcal),
                                 yEnd: .value("Total", point.totalKcal))
                            .foregroundStyle(StrandPalette.energyActive.opacity(0.22))
                        LineMark(x: .value("Time", point.timestamp),
                                 y: .value("Burned", point.totalKcal))
                            .foregroundStyle(StrandPalette.energyHighlight)
                            .lineStyle(.init(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    }
                    if let last = timeline.last, let projected = summary.projectedTotalBurn,
                       let midnight = Calendar.current.date(byAdding: .day, value: 1,
                                                            to: Calendar.current.startOfDay(for: last.timestamp)) {
                        LineMark(x: .value("Forecast time", last.timestamp),
                                 y: .value("Forecast", last.totalKcal), series: .value("Series", "forecast"))
                            .foregroundStyle(StrandPalette.textTertiary)
                            .lineStyle(.init(lineWidth: 2, dash: [6, 5]))
                        LineMark(x: .value("Forecast time", midnight),
                                 y: .value("Forecast", projected), series: .value("Series", "forecast"))
                            .foregroundStyle(StrandPalette.textTertiary)
                            .lineStyle(.init(lineWidth: 2, dash: [6, 5]))
                    }
                }
                .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 4)) }
                .frame(height: 190)
                if summary.forecastStatus == .learning {
                    Text("Forecast is learning from complete days. Only energy already burned is shown.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
        }
    }

    private var emptyState: some View {
        NoopCard(tint: StrandPalette.energyResting) {
            HStack(spacing: 14) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(StrandPalette.energyHighlight)
                    .frame(width: 48, height: 48)
                    .background(StrandPalette.energyHighlight.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text("Nothing recorded yet today.")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("Energy appears as soon as a connected source records today's activity.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
        }
    }

    /// A long-horizon comparison, never a replacement for today's WHOOP estimate. It appears only
    /// after enough complete nutrition and weight history exists; absence is quieter and more honest
    /// than a permanently "learning" card for users who do not track food.
    private func adaptiveComparison(_ estimate: AdaptiveExpenditureEstimate) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Adaptive expenditure", trailing: adaptiveConfidence(estimate.confidence))
            NoopCard {
                VStack(alignment: .leading, spacing: 8) {
                    row("Estimated daily average", formattedRange(estimate))
                    row("Observation window", "\(estimate.windowDays) days")
                    row("Logged intake coverage", percent(estimate.intakeCoverage))
                    Text("Calculated retrospectively from imported calories-in and your weight trend. It is a separate estimate and does not replace or calibrate today's WHOOP burn.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Technical provenance remains fully inspectable, but no longer competes with the useful daily
    /// summary and charts on first paint.
    private func technicalDetails(_ s: DailyEnergySummary) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Data quality & calculation", trailing: confidenceLabel(s.confidence))
            NoopCard(tint: StrandPalette.energyResting) {
                DisclosureGroup(isExpanded: $technicalDetailsExpanded) {
                    VStack(alignment: .leading, spacing: 10) {
                        Divider().overlay(StrandPalette.hairline)
                        provenanceRows(s)
                        Divider().overlay(StrandPalette.hairline)
                        calibrationContent
                    }
                    .padding(.top, 8)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.shield.fill")
                            .foregroundStyle(confidenceColor(s.confidence))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("How today's number was calculated")
                                .font(StrandFont.headline)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text(compactProvenanceLine(s) ?? sourceLabel(s.source))
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                    }
                }
                .tint(StrandPalette.energyHighlight)
            }
        }
    }

    @ViewBuilder private func provenanceRows(_ s: DailyEnergySummary) -> some View {
        row("Source", sourceLabel(s.source))
        if let energy = s.coverage.energy { row("Energy coverage", percent(energy)) }
        if let movement = s.coverage.movement { row("Hours with movement", percent(movement)) }
        if let bmr = s.estimatedBMR24h {
            row("Estimated basal rate per 24 h", "\(Int(bmr.rounded())) kcal/day")
        }
        if let weight = s.modelWeightKg {
            let source = s.modelWeightSource == "history"
                ? String(localized: "weight history") : String(localized: "profile")
            row("Body weight used", "\(weight.formatted(.number.precision(.fractionLength(1)))) kg · \(source)")
        }
        if let raw = s.rawWhoopTotalKcal { row("Model", "WHOOP v5 · \(Int(raw.rounded())) kcal") }
        if let uncertainty = s.uncertaintyFraction {
            row("Confidence", "±\(Int((uncertainty * 100).rounded())) %")
        }
        if s.unresolvedElevatedHRSeconds > 0 {
            let minutes = Int((Double(s.unresolvedElevatedHRSeconds) / 60).rounded())
            row("Unexplained elevated heart rate", "\(minutes) min")
            Text("This time had elevated heart rate without confirmed movement or a workout. NOOP does not count it as activity and widens the uncertainty range.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
        }
    }

    private var calibrationContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Calibration", isOn: Binding(
                get: { calibration.status == .active || calibration.status == .learning },
                set: { enabled in Task { await setCalibration(enabled) } }))
                .disabled(updatingCalibration)
            HStack {
                Text(calibrationLabel(calibration.status))
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                Spacer()
                if let factor = calibration.factor {
                    Text(verbatim: formattedCalibrationFactor(factor))
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
            }
            if calibration.sampleDays > 0 {
                row("Days", "\(calibration.sampleDays) · \(calibration.sampleBuckets) samples")
            }
            if calibration.status == .active || calibration.status == .paused {
                Button("Reset", role: .destructive) {
                    Task {
                        updatingCalibration = true
                        calibration = await repo.resetEnergyCalibration()
                        summaries = await repo.energySummaries(
                            days: 30, profile: Repository.analyticsProfile(profile))
                        updatingCalibration = false
                    }
                }
                .disabled(updatingCalibration)
            }
        }
    }

    private func row(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(label).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            Spacer()
            Text(value).font(StrandFont.caption).foregroundStyle(StrandPalette.textPrimary)
        }
    }

    private var history: [TrendPoint] {
        summaries.compactMap { s in
            // Today's number is intentionally "so far". Plotting it beside complete past days would
            // manufacture a dramatic drop every morning; the live card above already owns that value.
            guard s.day != Repository.localDayKey(Date()) else { return nil }
            guard let total = s.totalBurnedSoFar, let date = WeightSeries.date(forDay: s.day) else { return nil }
            return TrendPoint(date: date, value: total)
        }
    }

    private var chart: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Daily burn", trailing: String(localized: "last 30 days"))
            NoopCard {
                TrendChart(points: history,
                           gradient: StrandPalette.energyGradient,
                           valueRange: chartRange,
                           height: 180,
                           valueFormat: { "\(Int($0.rounded())) kcal" },
                           dateFormat: { $0.formatted(date: .abbreviated, time: .omitted) },
                           accessibilityLabel: String(localized: "Daily energy burn"))
            }
        }
    }

    /// Fitted to the data, not anchored at zero: a day's burn varies by a few hundred kcal around a
    /// couple of thousand, and a zero-based axis would flatten every real difference.
    private var chartRange: ClosedRange<Double> {
        let values = history.map(\.value)
        guard let lo = values.min(), let hi = values.max() else { return 0...3_000 }
        let pad = max(100.0, (hi - lo) * 0.2)
        return max(0, lo - pad)...(hi + pad)
    }

    /// "WHOOP · 87 % captured · ±8 %" — nil when there's no coverage percentage to summarize
    /// (`coverage.energy` is only ever set for a WHOOP or Apple source; steps/profile days don't have
    /// a wear-duration signal, so this line would either fabricate a "0%" or need its own qualifier —
    /// the `row(...)` breakdown below already covers those honestly, unaided).
    ///
    /// "WHOOP" / "Apple Health" are brand names — `verbatim`, never translated, the same treatment the
    /// "Model" row above already gives "WHOOP · N kcal". `uncertaintyFraction` is populated only for a
    /// WHOOP day (`EnergyEngine.summarize`: `clean.strapTotalKcal == nil ? nil : ...`), so the ± term
    /// appears there and there only — nothing here needs to special-case that.
    private func compactProvenanceLine(_ s: DailyEnergySummary) -> String? {
        guard let energy = s.coverage.energy else { return nil }
        let source: String
        switch s.source {
        case .strapWornTime: source = "WHOOP"
        case .appleSplit:    source = "Apple Health"
        case .mixed, .stepsEstimate, .profileOnly: return nil
        }
        var line = "\(source) · \(percent(energy)) \(String(localized: "captured"))"
        if let uncertainty = s.uncertaintyFraction {
            line += " · ±\(Int((uncertainty * 100).rounded())) %"
        }
        return line
    }

    private func sourceLabel(_ source: EnergySource) -> String {
        switch source {
        case .appleSplit:    return String(localized: "Apple Health (active + basal)")
        case .strapWornTime: return String(localized: "Strap, worn-time estimate")
        case .mixed:         return String(localized: "Several sources")
        case .stepsEstimate: return String(localized: "Steps estimate")
        case .profileOnly:   return String(localized: "Profile only")
        }
    }

    private func confidenceLabel(_ confidence: ScoreConfidence) -> String {
        switch confidence {
        case .solid:       return String(localized: "High")
        case .building:    return String(localized: "Partial")
        case .calibrating: return String(localized: "Low")
        }
    }

    private func confidenceColor(_ confidence: ScoreConfidence) -> Color {
        switch confidence {
        case .solid: return StrandPalette.statusPositive
        case .building: return StrandPalette.statusWarning
        case .calibrating: return StrandPalette.textTertiary
        }
    }

    private func calibrationLabel(_ status: EnergyCalibrationStatus) -> String {
        switch status {
        case .off:      return String(localized: "Off")
        case .learning: return String(localized: "Learning")
        case .active:   return String(localized: "Active")
        case .paused:   return String(localized: "Paused")
        }
    }

    private func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded())) %"
    }

    private func formattedCalibrationFactor(_ factor: Double) -> String {
        "×" + factor.formatted(.number.precision(.fractionLength(3)))
    }

    private func formattedRange(_ estimate: AdaptiveExpenditureEstimate) -> String {
        let centre = Int(estimate.estimatedDailyKcal.rounded())
        let lower = Int(estimate.lowerBoundKcal.rounded())
        let upper = Int(estimate.upperBoundKcal.rounded())
        return "~\(centre) kcal/day · \(lower)–\(upper)"
    }

    private func adaptiveConfidence(_ confidence: AdaptiveExpenditureConfidence) -> String {
        switch confidence {
        case .building: return String(localized: "Building")
        case .moderate: return String(localized: "Moderate")
        case .high:     return String(localized: "High")
        }
    }

    private func loadIfNeeded() async {
        guard !loaded, !loading else { return }
        loading = true
        let analyticsProfile = Repository.analyticsProfile(profile)

        // Paint from the store first. A model-version migration must never hold the entire detail
        // screen hostage while it walks months of raw one-second movement rows.
        calibration = await repo.energyCalibrationState()
        summaries = await repo.energySummaries(days: 30,
                                               profile: analyticsProfile)
        timeline = await repo.todayEnergyTimeline(profile: analyticsProfile)
        adaptiveEstimate = await repo.adaptiveExpenditureEstimate()
        loaded = true
        loading = false

        // Rebuild only the live day on entry, then repaint. The normal completed-offload path owns
        // the 120-day backfill; doing that synchronously here made a 2.4 GB library look like an empty
        // card for minutes.
        refreshingToday = true
        await repo.refreshWhoopEnergyModel(days: 1, profile: analyticsProfile)
        summaries = await repo.energySummaries(days: 30, profile: analyticsProfile)
        timeline = await repo.todayEnergyTimeline(profile: analyticsProfile)
        calibration = await repo.energyCalibrationState()
        refreshingToday = false
    }

    private func setCalibration(_ enabled: Bool) async {
        guard !updatingCalibration else { return }
        updatingCalibration = true
        calibration = await repo.setEnergyCalibrationEnabled(
            enabled, profile: Repository.analyticsProfile(profile))
        summaries = await repo.energySummaries(days: 30,
                                               profile: Repository.analyticsProfile(profile))
        updatingCalibration = false
    }
}
