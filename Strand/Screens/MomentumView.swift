import SwiftUI
import StrandAnalytics
import StrandDesign
import WhoopStore

/// The Momentum dashboard — the whole ranked feed, where the Today card shows only its top entry.
///
/// The card answers "what is the one thing right now". This answers "what is going on with me today",
/// which is a different question and needs room: the leading message drawn large, then everything else
/// grouped by how much it matters, each with the evidence behind it rather than just a sentence.
///
/// **The graphics are data, not decoration.** Every visual here is an existing design-system component
/// fed with series the app already holds — `Sparkline` for a trend, `PipBar` for a week's sessions,
/// `GlowRing` for a completion fraction. That is deliberate: it makes the screen rich WITHOUT depending
/// on artwork that does not exist yet, so nothing looks unfinished while illustrations are outstanding.
/// The hand-painted washes appear only where `MomentumScene` actually maps one.
struct MomentumView: View {
    /// The ranked feed, top-first, as the Today screen resolved it.
    let messages: [MomentumMessage]
    /// False when no feed has been resolved YET. Distinct from an empty feed: "nothing to flag" is a
    /// real, honest answer, but claiming it before anything has been worked out would be a lie.
    var isResolved: Bool = true
    /// Recent daily rows, for the small evidence charts beside a message.
    var recentDays: [DailyMetric] = []
    /// Runs a message's action.
    var onAction: (MomentumDestination) -> Void = { _ in }
    /// Which destinations THIS host can actually open. An action outside the set is not drawn at all
    /// rather than drawn dead: the Today sheet can flip every one of Today's own sheets, the standalone
    /// screen (More index / macOS sidebar) has no such state and can only serve some. A visible button
    /// that does nothing is the defect this exists to prevent.
    var availableDestinations: Set<MomentumDestination> = [
        .chargeBreakdown, .goalJourney, .plan, .liveSession,
    ]

    var body: some View {
        ScreenScaffold(title: "Momentum",
                       subtitle: "What matters most for you right now") {
            if !isResolved {
                unresolvedState
            } else if messages.isEmpty {
                emptyState
            } else {
                if let lead = messages.first {
                    hero(lead)
                }
                ForEach(MomentumTier.allCases) { tier in
                    let group = messages.dropFirst().filter { tier.contains($0.kind) }
                    if !group.isEmpty {
                        section(tier, Array(group))
                    }
                }
            }
        }
    }

    // MARK: - Empty

    /// An honest empty state. The feed returning nothing is a real outcome — it means there is nothing
    /// true to flag — so it says that rather than filling the screen with something invented.
    private var emptyState: some View {
        NoopCard(padding: NoopMetrics.cardPadding, tint: StrandPalette.chargeColor) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Nothing to flag right now")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("Momentum stays quiet when there's nothing worth acting on. Wear the strap and log your day, and it fills in.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Shown when the feed has not been worked out yet. The assembly lives on the Today screen (see
    /// `MomentumStore`), so opening this from the index on a cold launch can genuinely arrive first.
    private var unresolvedState: some View {
        NoopCard(padding: NoopMetrics.cardPadding, tint: StrandPalette.chargeColor) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Working out what matters")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("Open Today once and this fills in.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Hero

    /// The leading message at full size: its illustration (where one exists), a completion ring for a
    /// message that HAS a fraction, the headline, and its action as a real button.
    @ViewBuilder
    private func hero(_ m: MomentumMessage) -> some View {
        NoopCard(padding: NoopMetrics.cardPadding, tint: tint(m)) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 16) {
                    if let p = m.progress {
                        GlowRing(fraction: p.fraction, value: p.fraction * 100,
                                 format: { "\(Int($0.rounded()))%" },
                                 color: tint(m), diameter: 78, lineWidth: 8)
                    } else {
                        iconTile(m, size: 56, symbolSize: 24)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(m.headline)
                            .font(StrandFont.title2)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(m.detail)
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let line = m.actionLine {
                    Text(line)
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                evidence(m)
                if let action = m.action, availableDestinations.contains(action.destination) {
                    // Secondary, not the gold/accent primary. The card's TINT is its signal — green for a
                    // good read, red for a bad one — and a full-width accent CTA sitting inside it
                    // overrides exactly the colour the message is trying to communicate. Neutral chrome
                    // keeps the tone the loudest thing on the card.
                    Button { onAction(action.destination) } label: {
                        Text(action.title)
                    }
                    .buttonStyle(.noopSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(alignment: .top) { wash(m, height: 140, opacity: 0.26) }
    }

    // MARK: - Grouped rest

    @ViewBuilder
    private func section(_ tier: MomentumTier, _ group: [MomentumMessage]) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            Text(tier.title).strandOverline()
            ForEach(Array(group.enumerated()), id: \.offset) { _, m in
                row(m)
            }
        }
    }

    @ViewBuilder
    private func row(_ m: MomentumMessage) -> some View {
        NoopCard(padding: 14, tint: tint(m)) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 12) {
                    iconTile(m, size: 38, symbolSize: 16)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(m.headline)
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(m.detail)
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let line = m.actionLine {
                            Text(line)
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                    if let delta = m.deltaText {
                        Text(delta)
                            .font(StrandFont.footnote.weight(.semibold))
                            .foregroundStyle(tint(m))
                    }
                }
                evidence(m)
                if let action = m.action, availableDestinations.contains(action.destination) {
                    Button { onAction(action.destination) } label: {
                        HStack(spacing: 3) {
                            Text(action.title).font(StrandFont.footnote.weight(.semibold))
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                        }
                        .foregroundStyle(tint(m))
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Evidence

    /// The chart that shows WHY a message is on screen. Each kind gets the one visual that actually
    /// carries its argument, and nothing gets a chart just to have one: a message with no series behind
    /// it renders no chart rather than a flat placeholder line.
    @ViewBuilder
    private func evidence(_ m: MomentumMessage) -> some View {
        switch m.kind {
        case .hrvTrend:
            series(recentDays.suffix(21).compactMap(\.avgHrv).filter { $0 > 0 }, tint: tint(m))
        case .recoveryRead:
            series(recentDays.suffix(21).compactMap(\.recovery), tint: tint(m))
        case .restDayNeeded:
            series(recentDays.suffix(14).compactMap(\.strain), tint: tint(m))
        case .sleepCatchUp:
            series(recentDays.suffix(14).compactMap(\.totalSleepMin).map { $0 / 60 }, tint: tint(m))
        case .stepGoal, .stepsBelowUsual:
            series(recentDays.suffix(14).compactMap(\.steps).map(Double.init), tint: tint(m))
        case .weeklyTrainingGoal, .milestone, .weightMilestone, .streak:
            if let p = m.progress {
                VStack(alignment: .leading, spacing: 4) {
                    PipBar(value: p.fraction * 100, range: 0...100, segments: 20,
                           tint: tint(m), height: 8)
                    Text(p.label)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
        case .statusOverride, .calibrating, .planDeviation, .trainingSuggestion:
            EmptyView()
        }
    }

    /// A sparkline, but only when there is enough of a series to mean anything. Two points is a line
    /// segment, not a trend, and drawing one would overstate what the app knows.
    @ViewBuilder
    private func series(_ values: [Double], tint: Color) -> some View {
        if values.count >= 5 {
            Sparkline(values: values,
                      gradient: Gradient(colors: [tint.opacity(0.55), tint]),
                      showsArea: true, showsHead: true)
                .frame(height: 34)
        }
    }

    // MARK: - Shared bits

    private func iconTile(_ m: MomentumMessage, size: CGFloat, symbolSize: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(tint(m).opacity(0.16))
            Image(systemName: MomentumSymbol.name(for: m.kind))
                .font(.system(size: symbolSize, weight: .semibold))
                .foregroundStyle(tint(m))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// The optional hand-painted wash, under the same rules `SceneHeroBackground` enforces: flat image,
    /// top-aligned, faded downward, capped so it stays atmosphere rather than a photograph.
    @ViewBuilder
    private func wash(_ m: MomentumMessage, height: CGFloat, opacity: Double) -> some View {
        if let asset = MomentumScene.assetName(for: m.kind) {
            Image(asset)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity)
                .frame(height: height, alignment: .top)
                .clipped()
                .opacity(opacity)
                .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private func tint(_ m: MomentumMessage) -> Color { MomentumTint.color(for: m.tone) }
}

// MARK: - Grouping

/// The headings the dashboard groups under — the same ladder `MomentumKind.tier` ranks by, given words.
/// Deriving the group from the kind's own tier (rather than a second hand-kept list) is what stops the
/// page's grouping and the feed's ordering from drifting apart.
enum MomentumTier: Int, CaseIterable, Identifiable {
    case urgent = 0, timeCritical = 1, goals = 2, trainingRecovery = 3, progress = 4, positive = 5

    var id: Int { rawValue }

    func contains(_ kind: MomentumKind) -> Bool { kind.tier == rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .urgent:           return "Right now"
        case .timeCritical:     return "Running out of time"
        case .goals:            return "Your goals"
        case .trainingRecovery: return "Training and recovery"
        case .progress:         return "Progress"
        case .positive:         return "Worth noting"
        }
    }
}

// MARK: - Shared look-up

/// Tone → colour, in one place so the card and the dashboard cannot tint the same message differently.
enum MomentumTint {
    /// `MomentumTone` → `StrandTone`, then the ONE tone-to-colour mapping the rest of the app already
    /// uses (`StatePill`, the Goals tile, connection dots). This used to be its own switch, and
    /// `.neutral` fell to `StrandPalette.accent` — the CHROME accent (brand mint by default), not a
    /// data colour at all. A neutral message (e.g. a step count with no verdict) rendered in a THIRD
    /// green next to Charge's real value-coloured green, which is exactly the kind of clash "give me
    /// Apple Health colours" was reacting to. Routing through `StrandTone` instead means `.neutral`
    /// resolves to `StrandPalette.textSecondary` — a muted grey that reads as "no verdict" rather than
    /// competing with the real status hues — and Momentum can never colour a tone differently from
    /// every other surface that uses the same word for it.
    static func color(for tone: MomentumTone) -> Color { strandTone(for: tone).color }

    static func strandTone(for tone: MomentumTone) -> StrandTone {
        switch tone {
        case .positive: return .positive
        case .neutral:  return .neutral
        case .caution:  return .warning
        case .critical: return .critical
        }
    }
}

/// Kind → SF Symbol, likewise shared. Exhaustive (no `default`) so a kind added later has to choose its
/// own symbol rather than silently inheriting a generic one.
enum MomentumSymbol {
    static func name(for kind: MomentumKind) -> String {
        switch kind {
        case .statusOverride:     return "pause.circle"
        case .calibrating:        return "gauge.with.dots.needle.bottom.50percent"
        case .planDeviation:      return "calendar.badge.exclamationmark"
        case .weeklyTrainingGoal: return "calendar.badge.checkmark"
        case .milestone:          return "flag"
        case .weightMilestone:    return "scalemass"
        case .restDayNeeded:      return "exclamationmark.triangle"
        case .recoveryRead:       return "heart"
        case .trainingSuggestion: return "figure.run"
        case .stepGoal:           return "figure.walk"
        case .stepsBelowUsual:    return "figure.walk.motion"
        case .sleepCatchUp:       return "bed.double"
        case .streak:             return "flame"
        case .hrvTrend:           return "chart.line.uptrend.xyaxis"
        }
    }
}

/// Standalone host for the Momentum dashboard — what the More index (iOS) and the sidebar (macOS) open.
///
/// It renders the feed Today published rather than resolving one of its own; see `MomentumStore` for
/// why. Its actions deep-link through the shared app model, because unlike the Today card it has no
/// sheet state of its own to flip.
struct MomentumScreen: View {
    @ObservedObject private var store = MomentumStore.shared
    @EnvironmentObject private var repo: Repository
    @State private var showGoalJourney = false

    /// What this surface can honour on its own. Charge-breakdown and live-session are Today's sheets and
    /// its state; offering them here would draw buttons that do nothing, so they are simply not drawn.
    private static let servable: Set<MomentumDestination> = [.goalJourney]

    var body: some View {
        MomentumView(messages: store.messages,
                     isResolved: store.updatedAt != nil,
                     recentDays: store.recentDays.isEmpty ? repo.days : store.recentDays,
                     onAction: { if $0 == .goalJourney { showGoalJourney = true } },
                     availableDestinations: Self.servable)
            .sheet(isPresented: $showGoalJourney) {
                NavigationStack {
                    CoachGoalJourneyScreen()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showGoalJourney = false }
                            }
                        }
                }
                .environmentObject(repo)
            }
    }
}
