import SwiftUI
import StrandAnalytics
import StrandCore
import StrandDesign

// MARK: - Training Load phase 2 on the Apple screens
//
// One advice card, one "enough?" card, the Lab card and the settings, drawn from `Repository.trainingGuidance`
// (docs/fork/TRAINING_LOAD_PLAN.md §8). Today, the Training tab and Training Load show the same cards, so the
// advice can never read two ways (Q5).

/// Today's advice: the stance, its reason, the offers and the rating to ask for.
struct TrainingAdviceCard: View {
    @EnvironmentObject private var repo: Repository
    let guidance: TrainingGuidanceReader.Snapshot
    var showOffers = true
    /// Off where the page already lists today's planned session (the Training tab's plan card).
    var showPlanned = true

    var body: some View {
        let advice = guidance.advice
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                Text(TrainingGuidanceText.overline).strandOverline()
                HStack(spacing: NoopMetrics.space2) {
                    Image(systemName: TrainingGuidanceText.symbol(advice.stance))
                        .font(.system(.title3, weight: .semibold))
                        .foregroundStyle(color(advice.stance))
                        .accessibilityHidden(true)
                    Text(TrainingGuidanceText.title(advice.stance))
                        .font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                }
                Text(TrainingGuidanceText.reason(advice))
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if advice.state == .done {
                    Text(TrainingGuidanceText.doneLine).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                }
                if advice.ateTooLittle {
                    Text(TrainingGuidanceText.ateTooLittle).font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
                let offers = guidance.offers.filter { offer in
                    if case .planned = offer { return showPlanned }
                    return true
                }
                if showOffers && !offers.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(offers.enumerated()), id: \.offset) { _, offer in
                            Label(TrainingGuidanceText.offer(offer), systemImage: TrainingGuidanceText.offerSymbol(offer))
                                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                        }
                    }
                }
                if let move = guidance.movablePlan {
                    // Q17, Q27: a planned session against the advice, moved only on a tap.
                    Text(TrainingGuidanceText.easierFits(move.title)).font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary).fixedSize(horizontal: false, vertical: true)
                    Button(TrainingGuidanceText.moveToTomorrow) {
                        CoachPlanStore.shared.reschedule(move.id, toDay: move.tomorrow)
                        Task { await repo.refreshTrainingGuidance() }
                    }
                    .font(StrandFont.subhead)
                }
                if let ask = guidance.askRating {
                    SessionRPECard(startTs: ask.startTs, sport: WorkoutSource.localizedDisplaySport(ask.sport),
                                   durationS: Double(ask.endTs - ask.startTs))
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func color(_ stance: AdviceStance) -> Color {
        switch stance {
        case .push: return StrandPalette.statusPositive
        case .steady: return StrandPalette.accent
        case .easy: return StrandPalette.statusWarning
        case .rest: return StrandPalette.statusCritical
        }
    }
}

/// "Enough this week?" against the focus target (Q6, Q20, Q33).
struct TrainingEnoughCard: View {
    let guidance: TrainingGuidanceReader.Snapshot

    var body: some View {
        if let week = guidance.thisWeek {
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    Text(TrainingGuidanceText.enoughTitle).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                    ProgressView(value: min(1, Double(week.equivalentMinutes) / Double(max(1, week.target.minutesLow))))
                        .tint(StrandPalette.accent)
                        .accessibilityHidden(true)
                    Text(TrainingGuidanceText.minutesLine(week)).font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                    Text(TrainingGuidanceText.strengthLine(week)).font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                    ForEach([TrainingGuidanceText.everydayLine(week), TrainingGuidanceText.ratedLine(week)].compactMap { $0 },
                            id: \.self) { line in
                        Text(line).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    }
                    if guidance.carried {
                        Text(TrainingGuidanceText.carried).font(StrandFont.caption).foregroundStyle(StrandPalette.statusPositive)
                    }
                    if week.target.balanceHint {
                        Text(TrainingGuidanceText.balanceHint).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    }
                    Text(TrainingGuidanceText.enoughCaption).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// The phase 2 settings: focus, the pulse that does not show effort, the morning advice, the Lab markers.
struct TrainingGuidanceSettings: View {
    @EnvironmentObject private var repo: Repository
    @AppStorage(TrainingGuidancePrefs.focusKey) private var focusRaw = ""
    @AppStorage(TrainingGuidancePrefs.pulseUnreliableKey) private var pulseUnreliable = false
    @AppStorage(TrainingGuidancePrefs.morningAdviceKey) private var morningAdvice = false
    @AppStorage(TrainingGuidancePrefs.labInstrumentsKey) private var labInstruments = false

    var body: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                VStack(alignment: .leading, spacing: 4) {
                    Picker(TrainingGuidanceText.focusTitle, selection: $focusRaw) {
                        Text(TrainingGuidanceText.focus(nil)).tag("")
                        ForEach(TrainingFocus.allCases, id: \.self) { f in
                            Text(TrainingGuidanceText.focus(f)).tag(f.rawValue)
                        }
                    }
                    Text(TrainingGuidanceText.focusCaption).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                }
                toggle(TrainingGuidanceText.pulseTitle, TrainingGuidanceText.pulseCaption, $pulseUnreliable)
                toggle(TrainingGuidanceText.morningTitle, TrainingGuidanceText.morningCaption, $morningAdvice)
                toggle(TrainingGuidanceText.labTitle, TrainingGuidanceText.labCaption, $labInstruments)
            }
        }
        .onChangeCompat(of: focusRaw) { _ in Task { await repo.refreshTrainingGuidance() } }
        .onChangeCompat(of: pulseUnreliable) { _ in Task { await repo.refreshTrainingGuidance() } }
    }

    private func toggle(_ title: String, _ caption: String, _ value: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(title, isOn: value)
            Text(caption).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The Lab markers (Q19, Q35): what each reads and how far its check has come. Never a verdict.
struct TrainingInstrumentsCard: View {
    @EnvironmentObject private var repo: Repository
    @State private var snapshot: TrainingInstrumentsReader.Snapshot?

    var body: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                Text(TrainingGuidanceText.labTitle).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                if let s = snapshot {
                    row("cadence", s.cadence)
                    row("recovery", s.recovery)
                    row("pace", s.pace)
                    Text(TrainingGuidanceText.everydayFitness).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ProgressView()
                }
            }
        }
        .task {
            guard let store = await repo.storeHandle() else { return }
            let options = await repo.trainingGuidanceOptions()
            snapshot = await TrainingInstrumentsReader.read(
                reader: repo.storeReader(store), maxHR: options.maxHR,
                dismissedWorkoutSpans: options.dismissedWorkoutSpans, firstWeekday: options.firstWeekday,
                appleVO2Weekly: [], days: repo.days)
        }
    }

    private func row(_ kind: String, _ i: TrainingInstrumentsReader.Instrument) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(TrainingGuidanceText.instrumentTitle(kind)).font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
            Text(TrainingGuidanceText.direction(i.reading.direction)).font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
            Text(TrainingGuidanceText.check(passes: i.check?.passes ?? false, pairs: i.check?.pairs))
                .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
        }
    }
}
