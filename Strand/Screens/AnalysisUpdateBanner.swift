import SwiftUI
import StrandDesign

/// A small card at the bottom of Today while the analysis migration an update brings recalculates stored
/// scores. It used to be visible only on the Settings card, so after an update the dashboard's numbers
/// could shift with nothing saying why. The routine analysis passes, which run many times a day, and the
/// manual 21-day recalculation in Settings (which shows its own progress there) never open it.
///
/// It reads the same engine state as that card (`analysisMaintenancePhase` and `analysisProgress`) and
/// the same progress copy (`AnalysisProgressFormat`), so the two cannot disagree. It appears only once a
/// pass has run for `appearDelay`, so a migration that finishes in a moment does not flash a card, and
/// after a pass it has shown it states the outcome for `lingerSeconds`, then goes.
struct AnalysisUpdateBanner: View {
    @EnvironmentObject private var engine: IntelligenceEngine

    @State private var visible = false
    @State private var outcome: Outcome?
    #if DEBUG
    /// `--demo-analysis-banner`: a scripted 21-day pass for screenshots, since demo data never migrates.
    @State private var demo: (phase: IntelligenceEngine.AnalysisMaintenancePhase, progress: AnalysisProgress?)?
    private static let demoRequested = CommandLine.arguments.contains("--demo-analysis-banner")
    #endif

    private var phase: IntelligenceEngine.AnalysisMaintenancePhase {
        #if DEBUG
        if let demo { return demo.phase }
        #endif
        return engine.analysisMaintenancePhase
    }

    private var progress: AnalysisProgress? {
        #if DEBUG
        if let demo { return demo.progress }
        #endif
        return engine.analysisProgress
    }

    static let appearDelay: TimeInterval = 1
    static let lingerSeconds: TimeInterval = 3

    enum Outcome: Equatable {
        case finished
        case failed(String)
    }

    /// What a maintenance phase means for this card. Pure, so the gate is unit-tested.
    enum Kind: Equatable {
        /// An analysis migration is running; the card may show.
        case running
        /// The pass ended. The card states this only if it was already showing.
        case ended(Outcome)
        /// Anything else: checking, the manual recalculation, refreshing today, idle. The card stays hidden.
        case quiet
    }

    static func kind(of phase: IntelligenceEngine.AnalysisMaintenancePhase) -> Kind {
        switch phase {
        case .migrating: return .running
        case .completed: return .ended(.finished)
        case .failed(let message): return .ended(.failed(message))
        case .idle, .checking, .manualRecent, .refreshingToday: return .quiet
        }
    }

    var body: some View {
        Group {
            if visible {
                card
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(NoopMotion.card, value: visible)
        .animation(NoopMotion.card, value: outcome)
        .task(id: phase) { await follow(phase) }
        #if DEBUG
        .task { await runDemo() }
        #endif
    }

    #if DEBUG
    private func runDemo() async {
        guard Self.demoRequested else { return }
        let start = Date()
        for day in 0...21 {
            let stage: AnalysisProgress.Stage = day == 0 ? .preparing : day == 21 ? .finishing : .scanning
            demo = (.migrating(from: 20, to: 26),
                    AnalysisProgress(stage: stage, completedDays: day, reusedDays: day / 3, totalDays: 21,
                                     startedAt: start, lastStepAt: Date()))
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if Task.isCancelled { return }
        }
        demo = (.completed(Date()), nil)
    }
    #endif

    private func follow(_ phase: IntelligenceEngine.AnalysisMaintenancePhase) async {
        switch Self.kind(of: phase) {
        case .running:
            outcome = nil
            guard !visible else { return }
            try? await Task.sleep(nanoseconds: UInt64(Self.appearDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            visible = true
        case .ended(let result):
            guard visible else { return }
            outcome = result
            try? await Task.sleep(nanoseconds: UInt64(Self.lingerSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            visible = false
            outcome = nil
        case .quiet:
            visible = false
            outcome = nil
        }
    }

    private var card: some View {
        HStack(alignment: .center, spacing: NoopMetrics.space3) {
            icon
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                Text(title)
                    .font(StrandFont.subhead.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                if outcome == nil, let progress {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                            Text(AnalysisProgressFormat.detailLine(progress, now: context.date))
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            ProgressView(value: progress.fraction)
                                .tint(StrandPalette.accent)
                        }
                    }
                } else if case .failed(let message) = outcome {
                    Text(message)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, NoopMetrics.space4)
        .padding(.vertical, NoopMetrics.space3)
        .frame(maxWidth: 520)
        .background(StrandPalette.surfaceRaised,
                    in: RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous))
        .padding(.horizontal, NoopMetrics.screenHPadding)
        .padding(.bottom, NoopMetrics.space2)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var icon: some View {
        switch outcome {
        case .finished:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(StrandPalette.statusPositive)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(StrandPalette.statusWarning)
        case nil:
            ProgressView().controlSize(.small)
        }
    }

    private var title: String {
        switch outcome {
        case .finished: return String(localized: "Calculations updated")
        case .failed: return String(localized: "The recalculation stopped")
        case nil: return String(localized: "Updating calculations…")
        }
    }
}
