import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - Heute Charge breakdown sheet (parity with TodayView.chargeBreakdownSheet)
//
// Opened by tapping the Charge ring on Heute (`HeuteRingsView.onChargeTap`). It explains WHY the Charge
// value is what it is, in Heute's own token set. The driver composition is the SHARED pure
// `ChargeBreakdownFormat.compute` that classic Today reads too, so the two screens can never describe the
// same day differently (the P5 shared-selector principle). Scope is Charge ONLY (Effort/Rest rings stay
// pure display) with NO new driver math — this is a presentation port of the classic sheet: a header
// carrying the Charge value + confidence tier tag, one row per engine `ChargeDriver`, and the relative
// skin-temp marker, plus the two honest empty states (calibrating countdown / no-data note). Every value
// is surfaced verbatim from the engine; nothing here recomputes a score, a delta or a tier.
//
// Colours come from `HeuteRedesignPalette` (fixed green/red), NOT the classic `ChargeBreakdownFormat`
// chip colours (`StrandPalette.recoveryColor`, chart-style dependent) — same reason `HeuteRingsView`
// keeps its own charge/effort/rest tokens (see HeuteRedesignPalette's doc comment).

struct HeuteChargeBreakdownSheet: View {
    /// The row the breakdown describes — the same one the ring shows (today's own scored row, else the
    /// carried last-scored day). Resolved by `HeuteRedesignView` and passed in.
    let row: DailyMetric?
    /// The full history the baseline folds over (`repo.days`), so the drivers score against the same
    /// baselines the engine used.
    let days: [DailyMetric]
    /// The merged Rest composite (0…100) the Rest ring reads, or nil — feeds the sleep-quality term.
    let restScore: Double?
    /// The resolved Charge state, so the header can draw the real value and the calibrating branch can read
    /// its banked-nights count without a second computation.
    let chargeDisplay: ChargeDisplay

    @Environment(\.dismiss) private var dismiss

    /// The night's relative skin-temp marker for the described row, or nil. Surfaced verbatim from the
    /// engine (no recompute), exactly as classic does.
    private var skinTempRel: SkinTempRelative? {
        RecoveryScorer.skinTempRelative(deviationC: row?.skinTempDevC)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // One `compute` call per body eval: drivers + confidence share the same baseline folds.
                    let breakdown = ChargeBreakdownFormat.compute(row: row, days: days, restScore: restScore)
                    if let breakdown, !breakdown.drivers.isEmpty {
                        header(confidence: breakdown.confidence)
                        driverList(breakdown.drivers)
                        if let rel = skinTempRel { HeuteSkinTempRow(rel: rel) }
                    } else if case .calibrating(let banked) = chargeDisplay {
                        // A calibrating / cold-start night has nothing to attribute — tap through to the
                        // honest countdown rather than an empty breakdown.
                        calibrating(banked: banked)
                    } else {
                        emptyNote
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(HeuteRedesignPalette.bg.ignoresSafeArea())
            .navigationTitle("What shaped your Charge")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(HeuteRedesignPalette.charge)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: Header — the Charge value + confidence tier tag

    @ViewBuilder
    private func header(confidence: ScoreConfidence) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let pct = chargeDisplay.pct {
                (Text("\(Int(pct.rounded()))")
                    .font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit()
                    + Text("%").font(.system(size: 16, weight: .semibold)))
                    .foregroundStyle(HeuteRedesignPalette.charge)
            }
            Spacer(minLength: 8)
            HeuteTierTag(confidence: confidence)
        }
    }

    // MARK: "What shaped it" — one card, one row per driver

    private func driverList(_ drivers: [ChargeDriver]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("What shaped it")
                .font(.system(size: 10, weight: .bold)).tracking(1.1).textCase(.uppercase)
                .foregroundStyle(HeuteRedesignPalette.ink3)
            let maxMag = drivers.map { abs($0.deltaPoints) }.max() ?? 1
            ForEach(Array(drivers.enumerated()), id: \.offset) { _, driver in
                HeuteChargeDriverRow(driver: driver, maxMagnitude: maxMag)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HeuteRedesignPalette.tile, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(HeuteRedesignPalette.line, lineWidth: 1))
    }

    // MARK: Empty states

    /// The calibrating countdown, mirroring classic's `chargeCalibrationCountdown` — the same pure copy
    /// helpers so the two screens read identically. `banked` is the nights gathered so far.
    private func calibrating(banked: Int) -> some View {
        let remaining = max(1, Baselines.minNightsSeed - banked)
        let countdown = ChargeBreakdownFormat.calibrationCountdown(nightsRemaining: remaining)
        let unlock = ChargeBreakdownFormat.calibrationUnlockCopy(scoreName: String(localized: "Charge"))
        let progress = ChargeBreakdownFormat.calibrationProgress(banked: banked, seed: Baselines.minNightsSeed)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(countdown).font(.system(size: 17, weight: .bold))
                    .foregroundStyle(HeuteRedesignPalette.ink)
                Spacer(minLength: 0)
                HeuteTierTag(confidence: .calibrating)
            }
            Text(unlock).font(.system(size: 14)).foregroundStyle(HeuteRedesignPalette.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Text(progress).font(.system(size: 12)).foregroundStyle(HeuteRedesignPalette.ink3)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HeuteRedesignPalette.tile, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(HeuteRedesignPalette.line, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Charge baseline calibrating. \(countdown), \(unlock). \(progress).")
    }

    /// The honest fallback when there is no value AND no running calibration — a navigated past day with no
    /// score, or a fresh strap with nothing banked. Reuses classic's copy verbatim, never a blank sheet.
    private var emptyNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No Charge breakdown yet").font(.system(size: 17, weight: .bold))
                .foregroundStyle(HeuteRedesignPalette.ink)
            Text(TodayView.needsStrapCaption).font(.system(size: 14))
                .foregroundStyle(HeuteRedesignPalette.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HeuteRedesignPalette.tile, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(HeuteRedesignPalette.line, lineWidth: 1))
    }
}

// MARK: - One driver row (Heute port of ChargeDriverRow)

/// One driver row: a signed point-delta chip (+N green / -N red), value vs baseline, a thin magnitude bar
/// proportional to the term's share of the day's biggest mover, and the plain-English verdict. Same fields
/// and chip semantics as the classic `ChargeDriverRow`, re-skinned to `HeuteRedesignPalette` (fixed green
/// `charge` for supporting, red `attn` for limiting) and Heute's `.system` fonts.
private struct HeuteChargeDriverRow: View {
    let driver: ChargeDriver
    /// The largest |deltaPoints| in the same breakdown, so each bar reads as a share of the biggest mover.
    var maxMagnitude: Int? = nil

    private var chipText: String { ChargeBreakdownFormat.chipLabel(deltaPoints: driver.deltaPoints) }
    private var chipHue: Color {
        if driver.deltaPoints > 0 { return HeuteRedesignPalette.charge }
        if driver.deltaPoints < 0 { return HeuteRedesignPalette.attn }
        return HeuteRedesignPalette.ink3
    }
    private var fraction: Double {
        let mag = Double(abs(driver.deltaPoints))
        let mx = Double(max(1, maxMagnitude ?? abs(driver.deltaPoints)))
        return min(1, mag / mx)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(LocalizedStringKey(driver.label))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(HeuteRedesignPalette.ink)
                Spacer(minLength: 8)
                Text(chipText)
                    .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(chipHue)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(chipHue.opacity(0.14), in: Capsule(style: .continuous))
            }
            // value vs baseline — the baseline line is omitted for terms with no learned baseline.
            HStack(spacing: 6) {
                Text(driver.valueText)
                    .font(.system(size: 12)).monospacedDigit()
                    .foregroundStyle(HeuteRedesignPalette.ink2)
                if !driver.baselineText.isEmpty {
                    Text("·").font(.system(size: 12)).foregroundStyle(HeuteRedesignPalette.ink3)
                    Text(driver.baselineText).font(.system(size: 12))
                        .foregroundStyle(HeuteRedesignPalette.ink3)
                }
                Spacer(minLength: 0)
            }
            // A thin magnitude bar tinted to the chip hue, reading the term's share of the biggest mover.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(HeuteRedesignPalette.track)
                    Capsule().fill(chipHue).frame(width: max(2, geo.size.width * fraction))
                }
            }
            .frame(height: 6)
            .accessibilityHidden(true)
            Text(LocalizedStringKey(driver.verdict))
                .font(.system(size: 12))
                .foregroundStyle(HeuteRedesignPalette.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ChargeBreakdownFormat.driverAccessibilityLabel(driver))
    }
}

// MARK: - Relative skin-temp row (Heute port of SkinTempDeviationRow)

/// The night's relative skin-temp marker: "Skin temperature · +0.3 C vs your normal" with the plain-English
/// tier word. A deviation from the personal normal, never a clinical absolute. Heute-tokened, warm accent.
private struct HeuteSkinTempRow: View {
    let rel: SkinTempRelative

    private var deviationText: String { ChargeBreakdownFormat.skinTempDeviationLabel(rel) }
    private var tierWord: String { ChargeBreakdownFormat.skinTempTierWord(rel.tier) }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "thermometer.medium")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(HeuteRedesignPalette.icRhr)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("Skin temperature")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(HeuteRedesignPalette.ink)
                    Text(deviationText)
                        .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(HeuteRedesignPalette.icRhr)
                }
                Text(tierWord).font(.system(size: 12)).foregroundStyle(HeuteRedesignPalette.ink3)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HeuteRedesignPalette.tile, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(HeuteRedesignPalette.line, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    /// Built as a plain `String` from already-localized fragments (`String(localized:)` + the two engine
    /// read-outs) rather than an interpolated string literal, so it does NOT mint a new `LocalizedStringKey`
    /// ("Skin temperature %@. %@.") that would ship untranslated — the word "Skin temperature" reuses the
    /// existing catalog key the visible `Text` above already carries.
    private var accessibilityText: String {
        "\(String(localized: "Skin temperature")) \(deviationText). \(tierWord)."
    }
}

// MARK: - Confidence tier tag (Heute port of ConfidenceTierChip)

/// A small tier tag (CALIBRATING / EST. / REL.) mapping the EXISTING `ScoreConfidence` onto Heute's fixed
/// hues (calibrating → slate ink3, building → blue Effort, solid → green Charge). Never recomputes the
/// confidence; the tag text comes from the shared `ChargeBreakdownFormat.tierTag`.
private struct HeuteTierTag: View {
    let confidence: ScoreConfidence

    private var tag: String { ChargeBreakdownFormat.tierTag(confidence) }
    private var hue: Color {
        switch confidence {
        case .solid:       return HeuteRedesignPalette.charge
        case .building:    return HeuteRedesignPalette.effort
        case .calibrating: return HeuteRedesignPalette.ink3
        }
    }

    var body: some View {
        Text(tag)
            .font(.system(size: 10, weight: .bold)).tracking(0.4)
            .foregroundStyle(hue)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule(style: .continuous).fill(hue.opacity(0.14)))
            .overlay(Capsule(style: .continuous).strokeBorder(hue.opacity(0.32), lineWidth: 1))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibility)
    }

    private var accessibility: String {
        switch confidence {
        case .calibrating: return String(localized: "Confidence: calibrating")
        case .building:    return String(localized: "Confidence: estimate")
        case .solid:       return String(localized: "Confidence: reliable")
        }
    }
}
