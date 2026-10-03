import SwiftUI
import StrandDesign
import StrandAnalytics

/// Today's Training Load card (design review 2026-10-03, variant 1): one quiet scale per lane, the lane's
/// verdict in one word, and how recovery is holding. It reads `TrainingLoadModel.snapshot`, the same
/// side-effect-free read the Training Load screen and the Coach use, so the three can never disagree.
///
/// Effort is today's load; this is the balance over weeks, which is why it has no ring and no headline
/// number. Colour comes from the band and verdict tokens the Training Load screen already uses, and only
/// the current band segment carries it.
struct LiquidTrainingLoadSection: View {
    @EnvironmentObject var repo: Repository
    let surfaceOpacity: Double

    @State private var payload: Payload?

    /// What the card shows, reduced from the snapshot so it can be cached cheaply.
    struct Payload: Equatable {
        struct LaneRow: Equatable, Identifiable {
            let kind: TrainingLaneKind
            let band: RelativeLoadBand?
            let verdict: LaneVerdict?
            let ratio: Double?
            let thresholds: LaneThresholds?
            var id: TrainingLaneKind { kind }
        }
        let lanes: [LaneRow]
        let recovery: RecoveryState
    }

    /// The snapshot reads seven weeks of sessions and cardio loads. Today recreates this card on every
    /// scroll back into view, so one read serves the card for a few minutes.
    @MainActor private static var cache: (day: String, at: Date, payload: Payload)?
    private static let cacheLifetime: TimeInterval = 5 * 60

    var body: some View {
        VStack(spacing: NoopMetrics.space2) {
            HStack(alignment: .firstTextBaseline) {
                Text("TRAINING LOAD").font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textSecondary)
                Spacer()
                NavigationLink(value: TabRoute.trainingLoad) {
                    HStack(spacing: 3) {
                        Text("All").font(StrandFont.caption)
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(StrandPalette.accent)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 2)
            .padding(.top, 4)

            NavigationLink(value: TabRoute.trainingLoad) { card }
                .buttonStyle(LiquidPressStyle())
        }
        .task(id: repo.today?.day) { await load() }
    }

    @ViewBuilder private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let payload, !payload.lanes.isEmpty {
                ForEach(Array(payload.lanes.enumerated()), id: \.element.id) { index, lane in
                    if index > 0 {
                        Rectangle().fill(StrandPalette.hairline).frame(height: NoopMetrics.hairlineWidth)
                            .padding(.vertical, NoopMetrics.space2)
                    }
                    laneRow(lane)
                }
                if let line = recoveryLine(payload.recovery) {
                    Label(line.text, systemImage: line.symbol)
                        .font(StrandFont.footnote)
                        .foregroundStyle(line.color)
                        .padding(.top, NoopMetrics.space3)
                }
            } else if payload != nil {
                Text("Log a workout and NOOP compares your training with your usual load.")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 44)
            }
        }
        .padding(NoopMetrics.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TodayCardSurface(tint: nil, surfaceOpacity: surfaceOpacity))
    }

    private func laneRow(_ lane: Payload.LaneRow) -> some View {
        HStack(alignment: .center, spacing: NoopMetrics.space3) {
            Image(systemName: lane.kind == .strength ? "dumbbell.fill" : "figure.run")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(lane.kind == .strength ? StrandPalette.metricPurple : StrandPalette.metricCyan)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 7) {
                Text(lane.kind == .strength ? "Strength" : "Cardio")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                LoadBandScale(band: lane.band, position: lane.band == nil ? nil : Self.position(lane))
            }
            Spacer(minLength: NoopMetrics.space2)
            Text(lane.verdict?.label ?? String(localized: "Learning your usual"))
                .font(lane.verdict == nil ? StrandFont.footnote : StrandFont.subhead)
                .foregroundStyle(lane.verdict?.color ?? StrandPalette.textTertiary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .combine)
    }

    private func recoveryLine(_ state: RecoveryState) -> (text: String, symbol: String, color: Color)? {
        switch state {
        case .holding: return (String(localized: "Recovery is keeping up"), "heart", StrandPalette.textSecondary)
        case .strained: return (String(localized: "Recovery is lagging behind"), "exclamationmark.triangle",
                                StrandPalette.statusWarningForeground)
        case .unknown: return nil
        }
    }

    /// Where the dot sits on the four-segment scale (0…1). Each segment spans its own band, so the dot
    /// always lands inside the segment the band names, using the lane's personal edges when it has them.
    static func position(_ lane: Payload.LaneRow) -> Double? {
        guard let ratio = lane.ratio, ratio.isFinite else { return nil }
        let below = lane.thresholds?.below ?? LaneEngine.provisionalBelow
        let above = lane.thresholds?.above ?? LaneEngine.provisionalAbove
        let wellAbove = lane.thresholds?.wellAbove ?? LaneEngine.wellAboveCeiling
        let widths = LoadBandScale.segmentWidths
        func span(_ value: Double, _ low: Double, _ high: Double) -> Double {
            high > low ? min(max((value - low) / (high - low), 0), 1) : 0
        }
        if ratio < below { return widths[0] * span(ratio, 0, below) }
        if ratio < above { return widths[0] + widths[1] * span(ratio, below, above) }
        if ratio < wellAbove { return widths[0] + widths[1] + widths[2] * span(ratio, above, wellAbove) }
        return widths[0] + widths[1] + widths[2] + widths[3] * span(ratio, wellAbove, wellAbove * 1.3)
    }

    private func load() async {
        let day = repo.today?.day ?? Repository.localDayKey(Date())
        if let cached = Self.cache, cached.day == day, Date().timeIntervalSince(cached.at) < Self.cacheLifetime {
            payload = cached.payload
            return
        }
        let prepared = await TrainingLoadModel.snapshot(repo: repo).prepared
        guard !Task.isCancelled else { return }
        func row(_ kind: TrainingLaneKind, _ lane: TrainingLoadModel.Lane, _ verdict: LaneVerdict?) -> Payload.LaneRow? {
            // A lane with nothing logged in its window has nothing to compare; it is left out.
            guard lane.possibleCount > 0 else { return nil }
            return Payload.LaneRow(kind: kind, band: lane.reading?.band, verdict: lane.reading?.band == nil ? nil : verdict,
                                   ratio: lane.reading?.trend?.ratio, thresholds: lane.reading?.thresholds)
        }
        let next = Payload(
            lanes: [row(.strength, prepared.strength, prepared.strengthVerdict),
                    row(.cardio, prepared.cardio, prepared.cardioVerdict)].compactMap { $0 },
            recovery: prepared.recovery.state)
        Self.cache = (day, Date(), next)
        payload = next
    }
}

/// Four segments (below, usual, higher, well above usual). Only the current band's segment is tinted;
/// the dot marks where the lane stands inside it.
struct LoadBandScale: View {
    let band: RelativeLoadBand?
    let position: Double?

    static let segmentWidths: [Double] = [0.24, 0.36, 0.22, 0.18]
    private static let bands: [RelativeLoadBand] = [.below, .usual, .higher, .muchHigher]

    var body: some View {
        GeometryReader { proxy in
            let gap: CGFloat = 2
            let usable = proxy.size.width - gap * 3
            ZStack(alignment: .leading) {
                HStack(spacing: gap) {
                    ForEach(Array(Self.bands.enumerated()), id: \.offset) { index, segmentBand in
                        Capsule(style: .continuous)
                            .fill(segmentBand == band ? segmentBand.color : StrandPalette.surfaceInset)
                            .frame(width: usable * Self.segmentWidths[index])
                    }
                }
                .frame(height: 6)
                if let position, let band {
                    Circle()
                        .fill(band.color)
                        .overlay(Circle().strokeBorder(StrandPalette.surfaceRaised, lineWidth: 2))
                        .frame(width: 13, height: 13)
                        .offset(x: min(max(proxy.size.width * position - 6.5, 0), proxy.size.width - 13))
                }
            }
            .frame(height: proxy.size.height)
        }
        .frame(height: 13)
        .accessibilityHidden(true)
    }
}
