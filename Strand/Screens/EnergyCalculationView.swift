import SwiftUI
import StrandAnalytics
import StrandDesign
import WhoopStore

// EnergyCalculationView.swift — "how do you know?", one level below "how much?".
//
// This was a DisclosureGroup at the bottom of the Energy detail screen. Everything in it is worth
// keeping and none of it is worth competing with the day's figure for the reader's first glance:
// a model generation, a weight source and a calibration factor are what someone comes looking for
// deliberately, on the day they distrust the number, and never otherwise. Nothing was dropped in
// the move — the row that leads here says which source and how much of the day it covered, which
// is the part that answers the question most of the time.

/// The wording every energy surface uses for provenance and certainty. Shared rather than
/// reimplemented per screen: the detail row's subtitle and this page's rows are the same claims,
/// and two copies is how "WHOOP · 99 % captured" comes to mean two different things.
enum EnergyProvenance {

    /// The model generation, read back out of the version string rather than restated. The literal
    /// "v5" that used to sit in the row below outlived the v6 bump and would have gone on claiming a
    /// generation the app no longer runs — on the one screen whose whole job is saying what produced
    /// the number.
    static var modelGeneration: String {
        WhoopDailyEnergyEstimate.modelVersion.split(separator: "-").last.map(String.init) ?? ""
    }

    static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded())) %"
    }

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

    static func confidenceLabel(_ confidence: ScoreConfidence) -> String {
        switch confidence {
        case .solid:       return String(localized: "High")
        case .building:    return String(localized: "Partial")
        case .calibrating: return String(localized: "Low")
        }
    }

    static func confidenceColor(_ confidence: ScoreConfidence) -> Color {
        switch confidence {
        case .solid:       return StrandPalette.statusPositive
        case .building:    return StrandPalette.statusWarning
        case .calibrating: return StrandPalette.textTertiary
        }
    }

    /// "WHOOP · 87 % captured · ±8 %" — nil when there's no coverage percentage to summarize
    /// (`coverage.energy` is only ever set for a WHOOP or Apple source; steps/profile days don't have
    /// a wear-duration signal, so this line would either fabricate a "0%" or need its own qualifier —
    /// the row breakdown on the page below already covers those honestly, unaided).
    ///
    /// "WHOOP" / "Apple Health" are brand names — `verbatim`, never translated, the same treatment the
    /// "Model" row gives "WHOOP · N kcal". `uncertaintyFraction` is populated only for a WHOOP day
    /// (`EnergyEngine.summarize`: `clean.strapTotalKcal == nil ? nil : ...`), so the ± term appears
    /// there and there only — nothing here needs to special-case that.
    static func compactLine(_ s: DailyEnergySummary) -> String? {
        guard let energy = s.coverage.energy else { return nil }
        let source: String
        switch s.source {
        case .strapWornTime: source = "WHOOP"
        case .appleSplit:    source = "Apple Health"
        case .mixed, .stepsEstimate, .loggedActivity, .profileOnly: return nil
        }
        var line = "\(source) · \(percent(energy)) \(String(localized: "captured"))"
        if let uncertainty = s.uncertaintyFraction {
            line += " · ±\(Int((uncertainty * 100).rounded())) %"
        }
        return line
    }
}

/// Where the day's figure came from, what it was calibrated against, and the separate long-horizon
/// estimate that never touches it.
struct EnergyCalculationView: View {
    let summary: DailyEnergySummary

    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var profile: ProfileStore

    @State private var calibration = EnergyCalibrationViewState.off
    @State private var adaptiveEstimate: AdaptiveExpenditureEstimate?
    @State private var updatingCalibration = false
    @State private var loaded = false
    /// The day's stored model row, for the aerobic ceiling its workouts were priced with.
    @State private var modelRow: WhoopDailyEnergyRow?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                SectionHeader("How this was calculated",
                              overline: "Energy",
                              trailing: EnergyProvenance.confidenceLabel(summary.confidence))
                NoopCard(tint: StrandPalette.energyResting) {
                    VStack(alignment: .leading, spacing: 10) { provenanceRows }
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                calibrationSection
                if let adaptiveEstimate { adaptiveComparison(adaptiveEstimate) }
            }
            .padding(NoopMetrics.screenPadding)
        }
        .navigationTitle(Text("Calculation"))
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        .task { await load() }
    }

    @ViewBuilder private var provenanceRows: some View {
        row("Source", EnergyProvenance.sourceLabel(summary.source))
        if let sessions = summary.loggedActivityKcal, sessions > 0 {
            // The row that answers the question this whole path exists for. Without it, a day whose
            // sessions WERE counted looks exactly like a day whose sessions were ignored, and the only
            // way to tell is to do the arithmetic by hand.
            let kcal = "\(Int(sessions.rounded()).formatted(.number.grouping(.automatic))) kcal"
            row("From logged sessions",
                summary.loggedActivityIsEstimated
                    ? "\(kcal) · \(String(localized: "estimated"))" : kcal)
            if summary.loggedActivityIsEstimated {
                note("At least one session had no energy recorded, so NOOP estimated it from its average heart rate, or from the activity's published energy cost when there was none.")
            }
        }
        if let energy = summary.coverage.energy { row("Energy coverage", EnergyProvenance.percent(energy)) }
        if let movement = summary.coverage.movement {
            row("Hours with movement", EnergyProvenance.percent(movement))
        }
        if let bmr = summary.estimatedBMR24h {
            row("Estimated basal rate per 24 h", "\(Int(bmr.rounded())) kcal/day")
        }
        if let weight = summary.modelWeightKg {
            let source = summary.modelWeightSource == "history"
                ? String(localized: "weight history") : String(localized: "profile")
            row("Body weight used", "\(weight.formatted(.number.precision(.fractionLength(1)))) kg · \(source)")
        }
        if let raw = summary.rawWhoopTotalKcal {
            row("Model", "WHOOP \(EnergyProvenance.modelGeneration) · \(Int(raw.rounded())) kcal")
        }
        if let uncertainty = summary.uncertaintyFraction {
            row("Confidence", "±\(Int((uncertainty * 100).rounded())) %")
        }
        if let modelRow { ceilingRows(modelRow) }
        if summary.unresolvedElevatedHRSeconds > 0 {
            let minutes = Int((Double(summary.unresolvedElevatedHRSeconds) / 60).rounded())
            row("Unexplained elevated heart rate", "\(minutes) min")
            note("This time had elevated heart rate without confirmed movement or a workout. NOOP does not count it as activity and widens the uncertainty range.")
        }
    }

    /// Which VO₂max the day's workouts were scaled to, and where it came from. The question a wrong
    /// workout figure raises first, answered on the page that exists for "how do you know?".
    @ViewBuilder private func ceilingRows(_ model: WhoopDailyEnergyRow) -> some View {
        if let peak = model.peakMET {
            let vo2 = (peak * PeakMETResolver.mlPerMET).formatted(.number.precision(.fractionLength(1)))
            row("VO₂max for workouts", "\(vo2) ml/kg/min · \(ceilingSource(model))")
            if PeakMETResolver.measurementAdvised(
                source: model.peakMETSource.flatMap(PeakMETResolution.Source.init(rawValue:)),
                weightKg: model.weightKg, heightCm: profile.heightCm) {
                note("Estimated from a formula that is not validated above a BMI of 40, so it can read well above your real value. A measurement is more accurate: an outdoor walk with an Apple Watch, or a lab value entered here.")
            }
            if let measured = model.measuredVO2max, let at = model.measuredWeightKg,
               abs(at - model.weightKg) >= 0.5 {
                let measuredText = measured.formatted(.number.precision(.fractionLength(1)))
                let atText = at.formatted(.number.precision(.fractionLength(1)))
                let nowText = model.weightKg.formatted(.number.precision(.fractionLength(1)))
                Text("Measured \(measuredText) ml/kg/min at \(atText) kg, converted to \(nowText) kg.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            row("VO₂max for workouts", String(localized: "not known yet"))
            note("No resting heart rate yet, so workouts are priced from the activity's published energy cost.")
        }
    }

    private func ceilingSource(_ model: WhoopDailyEnergyRow) -> String {
        let date = model.peakMETSourceDay.flatMap(WeightSeries.date(forDay:))
            .map { $0.formatted(date: .abbreviated, time: .omitted) } ?? ""
        switch model.peakMETSource {
        case PeakMETResolution.Source.manual.rawValue:
            return String(localized: "entered \(date)")
        case PeakMETResolution.Source.appleWatch.rawValue:
            return String(localized: "Apple Watch, \(date)")
        default:
            return String(localized: "estimated, activity level \(model.activityLevel ?? 1)")
        }
    }

    private var calibrationSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Calibration", trailing: calibrationLabel(calibration.status))
            NoopCard {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Calibrate against Apple Watch", isOn: Binding(
                        get: { calibration.status == .active || calibration.status == .learning },
                        set: { enabled in Task { await setCalibration(enabled) } }))
                        .disabled(updatingCalibration)
                    if let factor = calibration.factor {
                        row("Applied factor", "×" + factor.formatted(.number.precision(.fractionLength(3))))
                    }
                    if calibration.sampleDays > 0 {
                        row("Days", "\(calibration.sampleDays) · \(calibration.sampleBuckets) samples")
                    }
                    note("A bounded reference multiplier on ACTIVE energy only. Apple stays a reference; it never replaces the strap's own measurement.")
                    if calibration.status == .active || calibration.status == .paused {
                        Button("Reset", role: .destructive) {
                            Task {
                                updatingCalibration = true
                                calibration = await repo.resetEnergyCalibration()
                                updatingCalibration = false
                            }
                        }
                        .disabled(updatingCalibration)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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
                    row("Logged intake coverage", EnergyProvenance.percent(estimate.intakeCoverage))
                    note("Calculated retrospectively from imported calories-in and your weight trend. It is a separate estimate and does not replace or calibrate today's WHOOP burn.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func row(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            Spacer(minLength: 8)
            Text(value).font(StrandFont.caption).foregroundStyle(StrandPalette.textPrimary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func note(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(StrandFont.caption)
            .foregroundStyle(StrandPalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func calibrationLabel(_ status: EnergyCalibrationStatus) -> String {
        switch status {
        case .off:      return String(localized: "Off")
        case .learning: return String(localized: "Learning")
        case .active:   return String(localized: "Active")
        case .paused:   return String(localized: "Paused")
        }
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

    private func load() async {
        guard !loaded else { return }
        loaded = true
        calibration = await repo.energyCalibrationState()
        adaptiveEstimate = await repo.adaptiveExpenditureEstimate()
        modelRow = await repo.whoopEnergyRow(day: summary.day)
    }

    private func setCalibration(_ enabled: Bool) async {
        guard !updatingCalibration else { return }
        updatingCalibration = true
        calibration = await repo.setEnergyCalibrationEnabled(
            enabled, profile: Repository.analyticsProfile(profile))
        updatingCalibration = false
    }
}
