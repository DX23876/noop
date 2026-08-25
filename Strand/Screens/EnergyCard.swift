import SwiftUI
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

    var body: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 12) {
                // Inline overline rather than a `SectionHeader` above the card: the card is dropped
                // into a section list beside Synthese and Ziele, which both label themselves from
                // inside their own surface.
                Text("ENERGY").strandOverline()
                header
                Divider().overlay(StrandPalette.hairline)
                splitRows
                if let note = qualityNote {
                    Text(note)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Header
    //
    // A flat headline rather than a ring. The card's own strongest state is the one with no data at
    // all — most days start there — and a 240° gauge with nothing to fill spends twice the height on
    // one estimated number. The composition below carries the visual weight instead.

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(headlineTotal)
                    .font(StrandFont.title1)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("total burned so far")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            Spacer()
            if let projected = summary.projectedTotalBurn {
                VStack(alignment: .trailing, spacing: 2) {
                    // "~" is load-bearing: this is an extrapolation of the day's rate so far, not a
                    // measurement, and the tilde is the cheapest way to keep saying so.
                    Text("~" + (kcal(projected) ?? "—"))
                        .font(StrandFont.title2)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("projected today")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
        }
    }

    /// True when nothing measured the day and the only figure is the modelled basal rate.
    private var isEstimateOnly: Bool { summary.source == .profileOnly }

    private var headlineTotal: String {
        guard let value = kcal(summary.totalBurnedSoFar) else { return "—" }
        return summary.source == .appleSplit ? value : "~" + value
    }

    // MARK: - Split

    /// Basal and active as SHARES of the day, not two numbers side by side. The point it makes: basal
    /// is typically three quarters of the total, which two adjacent figures never showed.
    @ViewBuilder
    private var splitRows: some View {
        // Nothing measured ⇒ no BARS. A bar at zero beside a number reads as a broken widget rather
        // than as "there is nothing to divide up yet", so the estimate falls back to plain figures.
        if isEstimateOnly || summary.totalBurnedSoFar == nil {
            plainFigures
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if let basal = summary.basalBurnedSoFar {
                    TypicalRangeRow(label: summary.source == .appleSplit
                                        ? String(localized: "Basal")
                                        : String(localized: "Basal (estimated)"),
                                    valueText: share(basal),
                                    trailingText: kcal(basal),
                                    value: fraction(basal),
                                    color: StrandPalette.metricAmber)
                } else if let bmr = summary.estimatedBMR24h {
                    TypicalRangeRow(label: String(localized: "Basal (estimated)"),
                                    valueText: share(bmr),
                                    trailingText: kcal(bmr),
                                    value: fraction(bmr),
                                    color: StrandPalette.metricAmber)
                }
                if let active = summary.activeBurnedSoFar {
                    TypicalRangeRow(label: String(localized: "Active"),
                                    valueText: share(active),
                                    trailingText: kcal(active),
                                    value: fraction(active),
                                    color: StrandPalette.effortColor)
                }
            }
        }
    }

    /// The no-composition fallback: the same two labelled figures the card carried before the bars,
    /// which is all there is to say when nothing measured the day. Keeps the estimated basal rate
    /// visible rather than hiding it because it has no share to draw.
    private var plainFigures: some View {
        HStack(alignment: .top, spacing: 0) {
            if let basal = summary.basalBurnedSoFar {
                figure(label: summary.source == .appleSplit ? "Basal" : "Basal (estimated)",
                       value: kcal(basal))
            } else {
                figure(label: "Basal (estimated)", value: kcal(summary.estimatedBMR24h))
            }
            figure(label: "Active", value: kcal(summary.activeBurnedSoFar))
        }
    }

    private func figure(label: LocalizedStringKey, value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value ?? "—")
                .font(StrandFont.bodyNumber)
                .foregroundStyle(value == nil ? StrandPalette.textSecondary : StrandPalette.textPrimary)
            Text(label).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A component's share of the day's total, 0…1. Nil total ⇒ 0: an empty bar rather than a full
    /// one, because "unknown" must never render as "all of it".
    private func fraction(_ value: Double) -> Double {
        guard let total = summary.totalBurnedSoFar, total > 0 else { return 0 }
        return min(1.0, max(0.0, value / total))
    }

    private func share(_ value: Double) -> String? {
        guard let total = summary.totalBurnedSoFar, total > 0 else { return nil }
        let pct = min(100, max(0, Int((value / total * 100).rounded())))
        return "\(pct) %"
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
}
// MARK: - Detail

/// The figures behind the card, plus where they came from. Progressive disclosure: the card answers
/// "how much?", this answers "how do you know?".
struct EnergyDetailView: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var profile: ProfileStore

    @State private var summaries: [DailyEnergySummary] = []
    @State private var loaded = false
    @State private var calibration = EnergyCalibrationViewState.off
    @State private var updatingCalibration = false

    private var today: DailyEnergySummary? {
        let key = Repository.localDayKey(Date())
        return summaries.last { $0.day == key }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                SectionHeader("Energy", overline: "Today")
                if let today {
                    EnergyCard(summary: today)
                    provenance(today)
                    calibrationControls
                } else {
                    Text("Nothing recorded yet today.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                if !history.isEmpty { chart }
            }
            .padding(NoopMetrics.screenPadding)
        }
        .navigationTitle(Text("Energy"))
        .task { await loadIfNeeded() }
    }

    /// Which sources produced today's number and how much of the day they saw. The point of the
    /// screen: a total is only worth as much as its coverage, and that has to be inspectable.
    private func provenance(_ s: DailyEnergySummary) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Data quality", trailing: confidenceLabel(s.confidence))
            NoopCard {
                VStack(alignment: .leading, spacing: 8) {
                    row("Source", sourceLabel(s.source))
                    if let energy = s.coverage.energy {
                        row("Energy coverage", percent(energy))
                    }
                    if let movement = s.coverage.movement {
                        row("Hours with movement", percent(movement))
                    }
                    if let bmr = s.estimatedBMR24h {
                        row("Estimated basal rate", "\(Int(bmr.rounded())) kcal/day")
                    }
                    if let raw = s.rawWhoopTotalKcal {
                        row("Model", "WHOOP · \(Int(raw.rounded())) kcal")
                    }
                    if let uncertainty = s.uncertaintyFraction {
                        row("Confidence", "±\(Int((uncertainty * 100).rounded())) %")
                    }
                    row("Calibration", calibrationLabel(s.calibrationStatus))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var calibrationControls: some View {
        NoopCard {
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
                           gradient: Gradient(colors: [StrandPalette.metricAmber.opacity(0.35),
                                                       StrandPalette.metricAmber]),
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

    private func loadIfNeeded() async {
        guard !loaded else { return }
        loaded = true
        await repo.refreshWhoopEnergyModel(
            days: 30, profile: Repository.analyticsProfile(profile))
        calibration = await repo.energyCalibrationState()
        summaries = await repo.energySummaries(days: 30,
                                               profile: Repository.analyticsProfile(profile))
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
