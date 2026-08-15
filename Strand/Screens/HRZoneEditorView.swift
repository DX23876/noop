import SwiftUI
import StrandDesign
import StrandAnalytics

/// Hand-set the five heart-rate zone bands.
///
/// Until now the only adjustable input to the zone model was HRmax; the boundaries themselves were
/// fixed at 50/60/70/80/90 % of it. That is a reasonable default and a poor fit for anyone who has had
/// a lactate or threshold test, or whose coach works to a different scheme — their Zone 2 simply isn't
/// where NOOP drew it, and every "did I hit Zone 2?" answer was against the wrong line.
///
/// The user edits the five LOWER bounds as % of HRmax; the top of Zone 5 is HRmax by definition and
/// isn't theirs to move. `HRZones.validatedEdges` owns what counts as a legal set, so this screen and
/// the stored value can never disagree about it.
///
/// Scope, stated on the screen rather than buried here: these bands change what is DISPLAYED as
/// time-in-zone and what the coach prescribes. They do NOT change the Effort score (a port of a
/// published %HRR method with its own thresholds — see `HRZones.swift`'s header), and they do not
/// touch zone bars that arrived inside a WHOOP CSV export, which carry WHOOP's own bands.
struct HRZoneEditorSheet: View {
    let onClose: () -> Void
    @EnvironmentObject var profile: ProfileStore

    /// Which definition the wearer is editing. Local until Save, like the bounds themselves.
    @State private var mode: HRZoneConfig.Mode = .auto

    /// The five lower bounds being edited, as PERCENTS (55, 65, …). Local draft: an intermediate state
    /// mid-edit is often illegal (raising Z2 past Z3 before raising Z3), so nothing is stored until the
    /// whole set validates. Seeded from the profile on appear.
    @State private var percents: [Double] = []

    /// The five lower bounds in BPM. Kept ALONGSIDE `percents` rather than converted on each mode
    /// switch: a round trip through the other unit rounds the numbers, so a wearer flicking between the
    /// two tabs to compare would watch their own figures drift.
    @State private var bpms: [Double] = []

    /// Step size for one tap in percent mode. Half a percent is finer than any real band boundary needs
    /// and keeps a 30→99 range reachable, matching the "variable but predictable" feel of the other
    /// steppers. Absolute mode steps a whole beat — the resolution of the data itself.
    private static let percentStep: Double = 0.5
    private static let bpmStep: Double = 1

    private var maxHR: Double { Double(profile.hrMax) }

    /// The draft as a validated 6-edge array in the CURRENT mode's unit, or nil while it is illegal.
    /// `.auto` is always legal and always the conventional set.
    private var draftEdges: [Double]? {
        switch mode {
        case .auto:    return HRZones.zoneEdges
        case .percent: return HRZones.validatedEdges(lowerPercents: percents.map { $0 / 100.0 })
        case .bpm:     return HRZones.validatedBpmEdges(lowerBpm: bpms, maxHR: maxHR)
        }
    }

    /// The zone set the preview renders — the draft when it's legal, the stored one until then, so the
    /// numbers never blank out mid-edit.
    private var previewSet: HRZoneSet {
        guard let edges = draftEdges else { return profile.hrZoneSet }
        switch mode {
        case .auto, .percent: return HRZones.zones(maxHR: maxHR, edges: edges)
        case .bpm:            return HRZones.zones(bpmEdges: edges, maxHR: maxHR)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(StrandPalette.hairline)
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                    explainerCard
                    modeCard
                    bandsCard
                    scopeCard
                }
                .padding(20)
            }
            Divider().overlay(StrandPalette.hairline)
            footerBar
        }
        #if os(macOS)
        .frame(width: 560, height: 720)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .noopSheetPresentation(largeFirst: true)
        #endif
        .background(StrandPalette.surfaceBase)
        .onAppear(perform: seedDrafts)
    }

    /// Seed both drafts from the profile. The mode the wearer is NOT on still needs sensible numbers to
    /// show the moment they switch to it, so an unset set is seeded from the resolved zones rather than
    /// left empty.
    private func seedDrafts() {
        guard percents.isEmpty else { return }
        let config = profile.hrZoneConfig
        mode = config.mode
        let resolved = profile.hrZoneSet
        percents = config.percentLowerBounds.isEmpty
            ? resolved.zones.map { ($0.lowerPct * 1000).rounded() / 10 }
            : config.percentLowerBounds.map { ($0 * 1000).rounded() / 10 }
        bpms = config.bpmLowerBounds.isEmpty
            ? resolved.zones.map { $0.lower.rounded(.up) }
            : config.bpmLowerBounds
    }

    // MARK: Header / footer

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("HEART-RATE ZONES").font(StrandFont.overline)
                    .tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textTertiary)
                Text("Set your own bands").font(StrandFont.rounded(26, weight: .bold))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("Max heart rate \(profile.hrMax) bpm").font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(20)
    }

    /// Save is disabled while the draft is illegal — the one place a bad set could otherwise reach
    /// storage. Reset switches back to the standard bands without discarding either draft, so it is
    /// undoable by simply picking the mode again.
    private var footerBar: some View {
        HStack(spacing: NoopMetrics.space3) {
            if mode != .auto {
                Button { mode = .auto } label: { Text("Use the standard bands") }
                    .buttonStyle(NoopButtonStyle(.secondary))
            }
            Spacer()
            Button {
                profile.setHRZoneConfig(draftConfig)
                onClose()
            } label: {
                Text("Save").frame(minWidth: 120)
            }
            .buttonStyle(NoopButtonStyle(.primary))
            .keyboardShortcut(.defaultAction)
            .disabled(draftEdges == nil)
        }
        .padding(NoopMetrics.space4)
    }

    /// The draft as the config that would be stored. Carries BOTH bound sets so `setHRZoneConfig` can
    /// keep the mode the wearer isn't on intact.
    private var draftConfig: HRZoneConfig {
        HRZoneConfig(mode: mode,
                     percentLowerBounds: percents.map { $0 / 100.0 },
                     bpmLowerBounds: bpms)
    }

    // MARK: Cards

    private var explainerCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("What these are", systemImage: "waveform.path.ecg")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("Each zone starts at a heart rate. The standard bands put those starts at 50, 60, 70, 80 and 90 % of your maximum, which suits most people. If you've had a threshold or lactate test, or you train to a coach's scheme, set your own here.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Zone 5 always ends at your maximum heart rate, so only the five starting points are yours to move.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The mode picker, with the one line that actually decides it for a wearer: percentages follow the
    /// maximum when it is re-estimated, absolute beats stay where they were put.
    private var modeCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 10) {
                Picker("How your zones are defined", selection: $mode) {
                    Text("Standard").tag(HRZoneConfig.Mode.auto)
                    Text("% of max").tag(HRZoneConfig.Mode.percent)
                    Text("Beats").tag(HRZoneConfig.Mode.bpm)
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("How your zones are defined")
                Text(modeBlurb)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var modeBlurb: String {
        switch mode {
        case .auto:
            return String(localized: "The usual 50/60/70/80/90 % of your maximum heart rate.")
        case .percent:
            return String(localized: "You set the percentages. They move with your maximum heart rate, so re-estimating it shifts every band.")
        case .bpm:
            return String(localized: "You set the heart rates themselves — what a threshold or lactate test gives you. They stay put when your maximum changes.")
        }
    }

    private var bandsCard: some View {
        NoopCard {
            VStack(spacing: 0) {
                ForEach(Array(previewSet.zones.enumerated()), id: \.offset) { index, zone in
                    if index > 0 {
                        Divider().overlay(StrandPalette.hairline).padding(.vertical, NoopMetrics.space2)
                    }
                    zoneRow(index: index, zone: zone)
                }
                if draftEdges == nil {
                    Divider().overlay(StrandPalette.hairline).padding(.vertical, NoopMetrics.space2)
                    Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.metricAmber)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// One band. The row always shows BOTH readings — the secondary line carries the bpm span in
    /// percent mode and the percentage span in absolute mode — so switching modes never hides the
    /// number the wearer came in knowing. Only the mode's own unit is editable; `.auto` shows the
    /// standard bands read-only.
    private func zoneRow(index: Int, zone: HRZone) -> some View {
        HStack(spacing: NoopMetrics.space3) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(StrandPalette.hrZoneColor(zone.number))
                .frame(width: 6, height: 34)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Zone \(zone.number)")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(secondaryLabel(zone))
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            Spacer(minLength: NoopMetrics.space2)
            HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space1) {
                Text(valueLabel(index: index, zone: zone))
                    .font(StrandFont.bodyNumber)
                    .foregroundStyle(mode == .auto ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                    .frame(width: NoopMetrics.formValueColumnWidth, alignment: .trailing)
                Text(mode == .bpm ? "bpm" : "%").font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .fixedSize()
            if mode != .auto {
                Stepper("Zone \(zone.number) starts at") {
                    adjust(index, up: true)
                } onDecrement: {
                    adjust(index, up: false)
                }
                    .labelsHidden()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(rowAccessibilityLabel(index: index, zone: zone))
    }

    /// What these bands do and don't reach. Stated plainly on the screen because the alternative is a
    /// user moving a band, watching their Effort not move, and concluding the setting is broken.
    private var scopeCard: some View {
        NoopCard(tint: StrandPalette.metricCyan) {
            VStack(alignment: .leading, spacing: 10) {
                Label("What this changes", systemImage: "info.circle")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("Your bands set the live zone readout, the zone split on a workout, and the zones your coach prescribes in.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("They don't change your Effort score, which is measured against your heart-rate reserve on a published method with its own fixed thresholds — so your history stays comparable. They also don't change zone bars that came in with a WHOOP export, which carry WHOOP's own bands.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Editing

    /// Nudge one bound in the current mode's unit, clamped to that mode's legal outer range.
    /// Deliberately does NOT push its neighbours: a band set is the wearer's shape, and silently
    /// dragging Zone 3 along because Zone 2 moved would undo an edit they made a moment ago. Crossing a
    /// neighbour disables Save until they fix it, with the reason spelled out.
    private func adjust(_ index: Int, up: Bool) {
        switch mode {
        case .auto:
            return
        case .percent:
            guard percents.indices.contains(index) else { return }
            let step = Self.percentStep
            let next = ((percents[index] + (up ? step : -step)) / step).rounded() * step
            percents[index] = min(max(next, HRZones.minEdge * 100), (1.0 - HRZones.minEdgeGap) * 100)
        case .bpm:
            guard bpms.indices.contains(index) else { return }
            let step = Self.bpmStep
            let next = ((bpms[index] + (up ? step : -step)) / step).rounded() * step
            bpms[index] = min(max(next, HRZones.minBpmEdge), max(HRZones.minBpmEdge, maxHR - HRZones.minBpmGap))
        }
    }

    /// The editable figure: the draft in the mode's own unit, or the resolved band for `.auto`.
    private func valueLabel(index: Int, zone: HRZone) -> String {
        switch mode {
        case .auto:
            return Self.percentText(zone.lowerPct)
        case .percent:
            guard percents.indices.contains(index) else { return "—" }
            return Self.percentText(percents[index] / 100.0)
        case .bpm:
            guard bpms.indices.contains(index) else { return "—" }
            return String(format: "%.0f", bpms[index].rounded())
        }
    }

    /// The other reading, so both are always on screen.
    private func secondaryLabel(_ zone: HRZone) -> String {
        mode == .bpm ? percentRange(zone) : bpmRange(zone)
    }

    private func percentRange(_ zone: HRZone) -> String {
        String(localized: "\(Self.percentText(zone.lowerPct))–\(Self.percentText(zone.upperPct)) % of max")
    }

    private func rowAccessibilityLabel(index: Int, zone: HRZone) -> String {
        mode == .bpm
            ? String(localized: "Zone \(zone.number) starts at \(valueLabel(index: index, zone: zone)) bpm, \(percentRange(zone))")
            : String(localized: "Zone \(zone.number) starts at \(valueLabel(index: index, zone: zone)) percent of maximum, \(bpmRange(zone))")
    }

    /// A band bound (a FRACTION of HRmax) as the shortest exact percent text: "65", or "62.5" when the
    /// user set a half. Shared with the Settings row's summary so the two never round differently.
    static func percentText(_ fraction: Double) -> String {
        let v = (fraction * 1000).rounded() / 10
        return abs(v - v.rounded()) < 1e-9
            ? String(format: "%.0f", v.rounded())
            : String(format: "%.1f", v)
    }

    private func bpmRange(_ zone: HRZone) -> String {
        // Zone 5's top edge is inclusive; the others are exclusive, so the printed upper bound is the
        // last bpm that still counts as this zone rather than the first of the next one.
        let upper = zone.number == 5 ? zone.upper.rounded() : (zone.upper.rounded() - 1)
        return String(localized: "\(Int(zone.lower.rounded()))–\(Int(upper)) bpm")
    }

    /// Why Save is disabled. Mode-aware, because the absolute mode has a second rule the percent mode
    /// doesn't: the top band has to leave room under the maximum, or Zone 5 would be empty.
    private var validationMessage: String {
        mode == .bpm
            ? String(localized: "Each zone has to start above the one before it, and Zone 5 has to start below your maximum of \(profile.hrMax) bpm.")
            : String(localized: "Each zone has to start above the one before it. Adjust the bands so they rise in order.")
    }
}
