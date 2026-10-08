import SwiftUI
import StrandDesign

// MARK: - WatchGlanceView — the first page of the watch app
//
// The Apple-Fitness-x-WHOOP look scaled to the wrist: the three NOOP scores as concentric rings (Charge
// outside, Effort, Rest inside) with a legend beside them that carries the numbers and the full names, so a
// long localized name ("Anstrengung") never has to squeeze under a 50 pt ring. Each score honours
// confidence: a calibrating or stale score draws an empty track and a dash plus "cal", NEVER a fabricated
// number. Below sit the live heart rate from the watch's own sensor and the phone's one-line sleep summary,
// and the snapshot's age ("as of 2h ago") so the scores never pretend to be live. When nothing has synced
// yet we show a friendly "open NOOP on your iPhone" state.
struct WatchGlanceView: View {
    @Environment(WatchScoreStore.self) private var store
    @Environment(WatchLiveHR.self) private var liveHR

    var body: some View {
        // Breathe / Workout / Intervals are their own pages in the deck (WatchRootView), so the glance
        // neither pushes nor links anywhere. The ScrollView is only a safety net: the layout fits one
        // screen on 42 mm and up, and on the smallest faces the last line scrolls instead of clipping.
        ScrollView {
            if let snap = store.snapshot {
                glance(snap)
            } else {
                emptyState
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .onAppear { liveHR.start() }
        .onDisappear { liveHR.stop() }
    }

    // MARK: Synced state

    private func glance(_ snap: WatchScoreSnapshot) -> some View {
        // One staleness decision for the whole glance: when the snapshot has aged out (per the shared
        // contract) every score takes its empty-track + dash branch so an arbitrarily old snapshot never
        // shows live-looking numbers. The recency line at the bottom says how old it is.
        let stale = snap.isStale()
        // The names ride a plain String into the score rows, so they are localized HERE; a bare literal
        // would bypass the string catalog. Charge is value-sampled through the one shared Charge colour so
        // the glance agrees with the complication on the same wrist.
        let scores = [
            WatchScore(label: String(localized: "Charge"), value: snap.charge,
                       calibrating: snap.chargeCalibrating || stale,
                       color: snap.charge.map { StrandPalette.chargeRingColor($0) } ?? StrandPalette.chargeColor),
            WatchScore(label: String(localized: "Effort"), value: snap.effort,
                       calibrating: snap.effortCalibrating || stale,
                       color: StrandPalette.effortColor),
            WatchScore(label: String(localized: "Rest"), value: snap.rest,
                       calibrating: snap.restCalibrating || stale,
                       color: StrandPalette.restColor),
        ]

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                // The legend takes its full natural width first; the rings get what is left, up to 84 pt.
                ConcentricScoreRings(scores: scores)
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: 84, maxHeight: 84)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(scores) { ScoreLegendRow(score: $0) }
                }
                .fixedSize()
            }

            // Heart rate and sleep share one line when they fit, and stack when they do not.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    heartRate
                    if !stale { sleepLine(snap.sleepSummary) }
                }
                VStack(alignment: .leading, spacing: 4) {
                    heartRate
                    // A stale snapshot's sleep line is out of date too, so drop it rather than imply today.
                    if !stale { sleepLine(snap.sleepSummary) }
                }
            }

            asOf(snap)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }

    /// Live heart rate from the watch's own sensor. Honest about denial: "HR unavailable" when HealthKit
    /// access was refused, a dash until the first sample lands, then the live BPM.
    private var heartRate: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: "heart.fill")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.statusCritical)
            if liveHR.denied {
                Text("HR unavailable")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            } else {
                Text(liveHR.bpm.map(String.init) ?? "–")
                    .font(StrandFont.rounded(20, weight: .semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.snappy, value: liveHR.bpm)
                Text("bpm")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    /// One-line sleep summary straight from the phone (e.g. "7h 12m · 81%"). Empty string = skip it.
    @ViewBuilder
    private func sleepLine(_ summary: String) -> some View {
        if !summary.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: "bed.double.fill")
                    .foregroundStyle(StrandPalette.restColor)
                Text(summary)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            .font(StrandFont.caption)
            .fixedSize()
            .accessibilityElement(children: .combine)
        }
    }

    /// The honesty line: how recent the synced scores are, straight from the shared contract so the
    /// glance and the complication phrase it identically ("Today" / "Yesterday" / "2h ago"). When the
    /// snapshot is stale the scores above are already dashes, and this line carries the recency.
    private func asOf(_ snap: WatchScoreSnapshot) -> some View {
        let fresh = snap.freshnessText()
        return Text(snap.isStale() ? String(localized: "stale · \(fresh)") : String(localized: "as of \(fresh)"))
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "iphone.gen3")
                .font(.title2)
                .foregroundStyle(StrandPalette.textTertiary)
            Text("Open NOOP on your iPhone to sync")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.top, 24)
    }
}

// MARK: - WatchScore — one score as the glance shows it

private struct WatchScore: Identifiable {
    let label: String
    let value: Double?
    let calibrating: Bool
    let color: Color

    var id: String { label }
    /// The ring fill, or nil when there is no number we are allowed to show (calibrating, stale, missing).
    var fraction: Double? {
        guard let value, !calibrating else { return nil }
        return min(max(value / 100, 0), 1)
    }
}

// MARK: - ConcentricScoreRings — the three scores as one Activity-style ring stack
//
// Charge outermost, Effort in the middle, Rest innermost. Track and arc share one line width so the arc
// sits exactly on its track; a score without a number keeps only its track. The fill eases in once on
// appear unless Reduce Motion is on.
private struct ConcentricScoreRings: View {
    let scores: [WatchScore]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        // Stroke and gap scale with the space the legend leaves, so three rings always keep an open centre.
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            rings(lineWidth: side * 0.11, gap: side * 0.025)
                .frame(width: side, height: side)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.smooth(duration: 0.8)) { appeared = true }
        }
    }

    private func rings(lineWidth: CGFloat, gap: CGFloat) -> some View {
        ZStack {
            ForEach(Array(scores.enumerated()), id: \.element.id) { index, score in
                let inset = CGFloat(index) * (lineWidth + gap) + lineWidth / 2
                ZStack {
                    Circle()
                        .stroke(score.color.opacity(0.22), lineWidth: lineWidth)
                    if let fraction = score.fraction {
                        Circle()
                            .trim(from: 0, to: appeared || reduceMotion ? fraction : 0)
                            .stroke(score.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                }
                .padding(inset)
            }
        }
    }
}

// MARK: - ScoreLegendRow — a score's number and name beside the rings

private struct ScoreLegendRow: View {
    let score: WatchScore

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if let value = score.value, !score.calibrating {
                Text("\(Int(value.rounded()))")
                    .font(StrandFont.rounded(17, weight: .semibold))
                    .foregroundStyle(score.color)
                    .monospacedDigit()
            } else {
                // "needs more data" is a dash plus a small "cal" marker, NEVER a number we did not earn.
                Text("–")
                    .font(StrandFont.rounded(17, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
                Text("cal")
                    .font(StrandFont.footnote)
                    .foregroundStyle(score.color)
            }
            Text(score.label)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(score.label)
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        if let value = score.value, !score.calibrating { return "\(Int(value.rounded()))" }
        return String(localized: "Calibrating")
    }
}
