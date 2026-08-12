import SwiftUI
import StrandDesign

/// The GUIDED goal-onboarding flow (#R12): one question at a time — welcome → type → details → why →
/// confirm — instead of the one-page editor's single wall of fields. It's an ALTERNATIVE to that editor,
/// not a replacement: the quick one-page path stays for edits and for anyone who'd rather fill it all in
/// at once. Re-startable at any time from the goal surface. Saves through the same
/// `CoachGoalStore.commit` the editor uses, so the two paths persist identically, and shows the same live
/// pace safety verdict (`GoalSafetyGate`) on the confirm step.
///
/// The wizard's own state lives in `GoalOnboardingDraft`, NOT in this view's `@State` — see that type for
/// why (a re-created view used to reset the flow to step one, which is what the "goal setup loops back to
/// 'Let's set a goal'" report actually was). This view only owns transient presentation flags.
///
/// The flow is deliberately VISUAL now: the goal's own kind carries a colour (`CoachIconColors`) through
/// the step pips, the type tiles and the confirm ring, so setting a goal looks like the thing it is
/// rather than a form. What it must never become is decorative arithmetic — the confirm ring fills ONLY
/// from a real `GoalProgress` reading, which is the same honesty rule the Journey page is built on.
struct CoachGoalOnboardingFlow: View {
    @ObservedObject private var store = CoachGoalStore.shared
    @ObservedObject private var draft = GoalOnboardingDraft.shared
    /// Read on the confirm step only, for the feasibility verdict. Every presentation path supplies it
    /// (`CoachGoalJourneyView` pushes from a view that has it; `CoachView`'s first-run sheet injects it
    /// explicitly) — a path that forgets would trap at runtime, which is why there are only two.
    @EnvironmentObject private var coach: AICoachEngine
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The same "Apple-inspired colors" switch the rest of Coach honours. Off → one accent everywhere.
    @AppStorage(AppleInspiredColorsPrefs.enabledKey) private var appleHealthColors = AppleInspiredColorsPrefs.defaultEnabled

    /// True when this is PUSHED onto an existing navigation stack rather than presented as a sheet, in
    /// which case it must not wrap itself in a second `NavigationStack`. The goal surface pushes it (a
    /// sheet opened from a view that may itself be in a sheet is the stacked-host glitch this file and
    /// `CoachGoalJourneyView` both carry scars from); first-run onboarding still presents it as a sheet.
    var pushed = false

    /// Called when the flow closes either way (finished or skipped), so first-run onboarding can mark
    /// itself as asked. Every presentation path passes this — a path that didn't left the one-time offer
    /// armed, so `CoachView` could re-present the flow on top of a setup already in progress.
    var onClose: () -> Void = {}

    private typealias Step = GoalOnboardingDraft.Step

    @State private var showReasonPrompt = false
    /// The other active goal of the picked kind (#R-multi-goal), offered to replace rather than silently
    /// overwritten or silently refused — same gate chain the quick editor uses.
    @State private var replaceCandidateId: UUID?
    @State private var showReplaceConfirm = false
    @State private var showLimitReached = false
    /// What the app can actually measure about the starting point, loaded once the confirm step is
    /// reached. Empty until then, and an empty `Evidence` simply yields no ring and no verdict — the
    /// step never waits on it, and never shows a placeholder number in its place.
    @State private var evidence = GoalFeasibility.Evidence()
    @State private var latestWeightKg: Double?

    /// Kinds that already have an active goal — shown as a note under the type picker so the collision is
    /// visible before confirming, not just at the end.
    private var kindAlreadyActive: Bool { store.activeGoal(for: draft.kind) != nil }

    private let twoColumns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
    private var bodyWeightKg: Double { ProfileStore().weightKg }

    private var safety: GoalSafetyGate.Assessment {
        GoalSafetyGate.assess(goal: draft.goal, bodyWeightKg: bodyWeightKg)
    }

    /// The colour the whole flow wears once a kind is picked. Data/identity encodings only — the pips,
    /// the tile marks, the confirm ring and the card wash — never a full-bleed chrome tint.
    private var kindTint: Color {
        appleHealthColors ? CoachIconColors.color(for: "coach.goal.\(draft.kind.rawValue)")
                          : StrandPalette.accent
    }

    var body: some View {
        if pushed {
            flow
        } else {
            NavigationStack { flow }
        }
    }

    private var flow: some View {
        VStack(spacing: 0) {
            progressBar
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    stepHeader
                    content
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                // The whole step re-enters as one unit when the step changes, so moving forward reads as
                // a new question arriving rather than a form redrawing in place.
                .id(draft.step)
                .transition(.softCard(reduced: reduceMotion))
            }
            footer
        }
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        #if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Skip") { close() }
            }
        }
        .alert("Why this pace?", isPresented: $showReasonPrompt) {
            TextField("e.g. deliberate cut phase", text: $draft.reason)
            Button("Cancel", role: .cancel) {}
            Button("Save anyway") { commit(acknowledging: true) }
        } message: {
            Text("This is faster than usually recommended. It's your call — tell me why and I'll note it, so I coach you through it instead of arguing with you every week.")
        }
        .confirmationDialog("Replace your existing goal?", isPresented: $showReplaceConfirm, titleVisibility: .visible) {
            Button("Replace it") { proceedPastLimitCheck() }
            Button("Cancel", role: .cancel) { replaceCandidateId = nil }
        } message: {
            Text("You already have an active \(draft.kind.label.localizedCatalogValue) goal. Replacing it closes that one out — its story stays in your history.")
        }
        .alert("You're at the limit", isPresented: $showLimitReached) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("You already have \(CoachGoalStore.maxActiveGoals) active goals — set one aside or close one out before adding another.")
        }
    }

    // MARK: - Chrome

    /// Segmented step pips in the goal's own colour, plus the step count in words. The pips replaced a
    /// plain `ProgressView`: five discrete steps deserve five discrete marks, and `PipBar` is the house
    /// signature for exactly that.
    private var progressBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            PipBar(value: Double(draft.step.rawValue + 1),
                   range: 0...Double(Step.allCases.count),
                   segments: Step.allCases.count,
                   tint: kindTint,
                   height: 6)
            Text("Step \(draft.step.rawValue + 1) of \(Step.allCases.count)")
                .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
        }
        .padding(.horizontal, 16).padding(.top, 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(draft.step.rawValue + 1) of \(Step.allCases.count)")
    }

    /// The step's title beside a medallion carrying the goal kind's mark. From the type step onward the
    /// medallion changes with the pick, so the choice stays visible while the details are filled in.
    private var stepHeader: some View {
        HStack(spacing: 12) {
            if draft.step != .welcome {
                Image(systemName: draft.kind.icon)
                    .font(.system(size: 22))
                    .foregroundStyle(kindTint)
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(kindTint.opacity(0.12)))
                    .overlay(Circle().strokeBorder(kindTint.opacity(0.28), lineWidth: 1))
                    .accessibilityHidden(true)
            }
            Text(LocalizedStringKey(draft.step.title))
                .font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if draft.step != .welcome {
                Button { withAnimation(StrandMotion.fade) { _ = draft.back() } } label: {
                    Image(systemName: "chevron.left")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
            }
            if draft.step == .confirm {
                NoopButton("Set my goal", systemImage: "checkmark", kind: .primary, fullWidth: true) {
                    attemptCommit()
                }
            } else {
                NoopButton(draft.step == .welcome ? "Get started" : "Next",
                           systemImage: "arrow.right", kind: .primary, fullWidth: true) {
                    withAnimation(StrandMotion.fade) { _ = draft.advance() }
                }
                .disabled(!draft.canAdvance)
            }
        }
        .padding(16)
        .background(.ultraThinMaterial)
    }

    // MARK: - Steps

    @ViewBuilder
    private var content: some View {
        switch draft.step {
        case .welcome: welcomeStep
        case .type:    typeStep
        case .details: detailsStep
        case .why:     whyStep
        case .confirm: confirmStep
        }
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("A few quick questions and your coach knows what you're working towards — so it can tell you where you stand, not just how you slept.")
                .font(StrandFont.body).foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Entirely optional. Everything else works without a goal, and you can change or drop it any time.")
                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var typeStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: twoColumns, spacing: 10) {
                ForEach(CoachGoal.Kind.allCases) { k in
                    GoalKindTile(kind: k,
                                 selected: draft.kind == k,
                                 tint: appleHealthColors
                                     ? CoachIconColors.color(for: "coach.goal.\(k.rawValue)")
                                     : StrandPalette.accent) {
                        withAnimation(StrandMotion.interactive) { draft.kind = k }
                        StrandHaptic.selection.play()
                    }
                }
            }
            if kindAlreadyActive {
                stepNote("You already have an active \(draft.kind.label.localizedCatalogValue) goal — continuing will offer to replace it.")
            } else if draft.kind == .weight {
                stepNote("I'll track your weight and plan your training around it — but I have no nutrition data, and that's where most of weight change is decided. I won't pretend otherwise.")
            } else if !draft.kind.isQuantified {
                stepNote("I can hold this goal and shape your training around it, but I can't measure it from your strap — so I won't invent progress numbers for it.")
            }
        }
    }

    private var detailsStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            field("Goal", placeholder: placeholderTitle, text: $draft.title)
            // "Next" stays disabled until this has a name (`canAdvance`) — on `.custom` it's the ONLY
            // field on this step, so an empty title otherwise reads as the flow silently refusing to
            // move, not as something the user needs to do. Say it plainly instead.
            if draft.trimmedTitle.isEmpty {
                stepNote("Give it a name to continue.")
            }
            if draft.kind.isQuantified {
                fromToRow
            }
            Toggle(isOn: $draft.hasTargetDate.animation(StrandMotion.fade)) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Target date").font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                    Text("Without one I can't tell you how you're tracking.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                }
            }
            .toggleStyle(.switch).appleInspiredTint("coach")
            if draft.hasTargetDate {
                targetDateRow
            }
        }
    }

    /// Baseline → target as ONE reading, with the unit stated once per side and an arrow between them,
    /// instead of two unrelated boxes. Same two `draft` fields underneath.
    private var fromToRow: some View {
        HStack(alignment: .bottom, spacing: 10) {
            field("From (\(draft.kind.unit))", placeholder: "now", text: $draft.baselineText, numeric: true)
            Image(systemName: "arrow.right")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .padding(.bottom, 10)
                .accessibilityHidden(true)
            field("To (\(draft.kind.unit))", placeholder: "target", text: $draft.targetText, numeric: true)
        }
    }

    /// Runway presets first, the full picker second. Most goals are "a couple of months out", and picking
    /// that from a calendar is the fiddliest thing in the whole flow.
    private var targetDateRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ForEach(GoalRunwayPreset.allCases) { preset in
                    Button {
                        withAnimation(StrandMotion.fade) { draft.targetDate = preset.date(from: Date()) }
                        StrandHaptic.selection.play()
                    } label: {
                        Text(LocalizedStringKey(preset.label))
                            .font(StrandFont.footnote)
                            .foregroundStyle(isPreset(preset) ? kindTint : StrandPalette.textSecondary)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Capsule().fill(isPreset(preset) ? kindTint.opacity(0.12)
                                                                        : StrandPalette.surfaceInset))
                            .overlay(Capsule().strokeBorder(isPreset(preset) ? kindTint.opacity(0.5)
                                                                             : StrandPalette.hairline,
                                                            lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isPreset(preset) ? [.isButton, .isSelected] : .isButton)
                }
                Spacer(minLength: 0)
            }
            DatePicker("Target date", selection: $draft.targetDate, in: Date()..., displayedComponents: .date)
                .datePickerStyle(.compact).appleInspiredTint("coach").labelsHidden()
                .accessibilityLabel("Target date")
            if let weeks = draft.goal.weeksRemaining(), weeks > 0 {
                Text("\(Int(weeks.rounded())) weeks to go")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    /// Whether the drafted date is (to the day) the one this preset would set.
    private func isPreset(_ preset: GoalRunwayPreset) -> Bool {
        Calendar.current.isDate(draft.targetDate, inSameDayAs: preset.date(from: Date()))
    }

    private var whyStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pick what's driving this — the coach uses it to shape its advice, not just decorate the screen.")
                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: twoColumns, spacing: 8) {
                ForEach(CoachGoal.MotivationTag.allCases) { tag in
                    GoalMotivationChip(tag: tag,
                                       selected: draft.motivationTags.contains(tag),
                                       tint: kindTint) {
                        withAnimation(StrandMotion.interactive) { draft.toggleMotivationTag(tag) }
                        StrandHaptic.selection.play()
                    }
                }
            }
            Divider().overlay(StrandPalette.hairline)
            field("Anything more personal? (optional)",
                  placeholder: "the reason you'll remember at 6am", text: $draft.motivation)
            Toggle(isOn: $draft.shareMotivation) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Share this with the coach").font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                    Text(draft.shareMotivation
                         ? "Sent to your AI provider along with the rest of your context."
                         : "Stays on this device. The coach won't see it.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch).appleInspiredTint("coach")
            .disabled(draft.motivation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    // MARK: - Confirm

    private var confirmStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            planCard
            feasibilityCard
            if let warning = safety.warning {
                NoopCard(padding: 14, tint: StrandPalette.statusWarning) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: safety.verdict == .veryAggressive
                              ? "exclamationmark.triangle.fill" : "info.circle.fill")
                            .foregroundStyle(safety.verdict == .veryAggressive
                                             ? StrandPalette.statusWarning : StrandPalette.accent)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("About that pace").strandOverline()
                            Text(warning).font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .task {
            // Loaded once, on the step that uses it. A failure to produce evidence is not an error state:
            // `Evidence()` is empty, which correctly yields no ring and an "I can't judge this" verdict.
            evidence = await coach.goalEvidence()
            latestWeightKg = await coach.latestLoggedWeightKg()
        }
    }

    /// The goal as it will be saved: its mark, its name, the one-line summary — and, when there is a REAL
    /// measurement behind it, a ring showing where the user is starting from. No measurement, no ring.
    private var planCard: some View {
        let reading = GoalProgress.reading(goal: draft.goal, evidence: evidence,
                                           latestWeightKg: latestWeightKg)
        return NoopCard(padding: 16, tint: kindTint) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 14) {
                    if let fraction = reading.fraction {
                        VStack(spacing: 4) {
                            GlowRing(fraction: fraction,
                                     value: fraction * 100,
                                     format: { String(format: "%.0f%%", $0) },
                                     color: kindTint,
                                     diameter: 84, lineWidth: 8)
                            Text("Where you're starting").strandOverline()
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Where you're starting")
                        .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
                    } else {
                        Image(systemName: draft.kind.icon)
                            .font(.system(size: 30))
                            .foregroundStyle(kindTint)
                            .frame(width: 84, height: 84)
                            .background(Circle().fill(kindTint.opacity(0.12)))
                            .overlay(Circle().strokeBorder(kindTint.opacity(0.28), lineWidth: 1))
                            .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(draft.trimmedTitle.isEmpty ? String(localized: "Your goal") : draft.trimmedTitle)
                            .font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(confirmSummary)
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                if let line = reading.line {
                    Text(line)
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// "Is this realistic?" — `GoalFeasibility`, which until now only ever reached the coach's own
    /// context. Only the VERDICT is surfaced here, as a localized line: the assessment's `rationale` is
    /// English prose assembled for the model's prompt, and putting that in a translated wizard would show
    /// a German user an English paragraph. The numbers behind it stay where they read properly — the
    /// Journey page and the coach's own answer.
    private var feasibilityCard: some View {
        let assessment = GoalFeasibility.assess(goal: draft.goal, evidence: evidence)
        return NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("Is this realistic?").strandOverline()
                    Spacer(minLength: 8)
                    StatePill(feasibilityTitle(assessment.verdict),
                              tone: feasibilityTone(assessment.verdict), showsDot: false)
                }
                Text(feasibilityLine(assessment.verdict))
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func feasibilityTitle(_ verdict: GoalFeasibility.Verdict) -> LocalizedStringKey {
        switch verdict {
        case .supported:   return "Supported"
        case .ambitious:   return "Ambitious"
        case .unrealistic: return "A stretch too far"
        case .unknown:     return "Can't say"
        }
    }

    private func feasibilityTone(_ verdict: GoalFeasibility.Verdict) -> StrandTone {
        switch verdict {
        case .supported:   return .positive
        case .ambitious:   return .accent
        case .unrealistic: return .warning
        case .unknown:     return .neutral
        }
    }

    private func feasibilityLine(_ verdict: GoalFeasibility.Verdict) -> LocalizedStringKey {
        switch verdict {
        case .supported:
            return "Your own history says this is a routine progression rather than a stretch."
        case .ambitious:
            return "Reachable, but it needs a consistent build and no interruptions."
        case .unrealistic:
            return "From where you are today this is a leap, and leaps are where injuries come from. Give it more runway, or aim a little lower — you can always raise it later."
        case .unknown:
            return "I can't judge this one from what I can measure, and I'd rather say so than guess. Set it anyway — I'll coach it either way."
        }
    }

    private var confirmSummary: String {
        var parts: [String] = [String(localized: "\(draft.kind.label.localizedCatalogValue) goal")]
        if draft.kind.isQuantified, let target = Double(draft.targetText.replacingOccurrences(of: ",", with: ".")) {
            parts.append(String(format: "target %g %@", target, draft.kind.unit))
        }
        if draft.hasTargetDate {
            parts.append(String(localized: "by \(draft.targetDate.formatted(date: .abbreviated, time: .omitted))"))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Pieces

    @ViewBuilder
    private func stepNote(_ text: LocalizedStringKey) -> some View {
        Text(text).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func field(_ label: String, placeholder: String, text: Binding<String>, numeric: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.localizedCatalogValue).strandOverline()
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                .disableAutocorrection(true)
                #if !os(macOS)
                .keyboardType(numeric ? .decimalPad : .default)
                #endif
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: CoachRadius.field, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: CoachRadius.field, style: .continuous)
                    .strokeBorder(StrandPalette.hairline, lineWidth: 1))
                .accessibilityLabel(label.localizedCatalogValue)
        }
    }

    private var placeholderTitle: String {
        switch draft.kind {
        case .run:         return "e.g. Run 5k without stopping"
        case .consistency: return "e.g. Train three times a week"
        case .sleep:       return "e.g. Sleep 7.5 hours a night"
        case .strength:    return "e.g. Get back to full-body strength work"
        case .weight:      return "e.g. Get to 78 kg"
        case .stress:      return "e.g. Fewer high-stress days each week"
        case .recovery:    return "e.g. Wake up feeling more recovered"
        case .custom:      return "e.g. Feel good on the hills again"
        }
    }

    // MARK: - Navigation & commit

    /// The gate chain (#R-multi-goal), same order as the quick editor's `attemptSave`: a kind collision or
    /// the active-goal ceiling first, then the pace-reason prompt.
    private func attemptCommit() {
        if let limit = store.canAdd(kind: draft.kind) {
            switch limit {
            case .kindAlreadyActive(let existingId):
                replaceCandidateId = existingId
                showReplaceConfirm = true
            case .tooManyActive:
                showLimitReached = true
            }
            return
        }
        proceedPastLimitCheck()
    }

    private func proceedPastLimitCheck() {
        if safety.requiresReason { showReasonPrompt = true } else { commit(acknowledging: false) }
    }

    private func commit(acknowledging: Bool) {
        let ack: CoachGoal.RiskAcknowledgement? = acknowledging
            ? CoachGoalRisk.acknowledgement(verdict: safety.verdict.rawValue, reason: draft.reason)
            : nil
        let clearStale = !acknowledging && (safety.verdict == .ok || safety.verdict == .notApplicable)
        // The guided flow always ADDS a new goal (#R-multi-goal) — never edits one in place, that's the
        // quick editor's job — replacing a same-kind collision when the user chose to at the gate above.
        store.commit(draft.goal, editingId: nil, replacing: replaceCandidateId,
                     acknowledgedRisk: ack, clearStaleAck: clearStale)
        StrandHaptic.commit.play()
        close()
    }

    /// The single exit: the shared draft is cleared here and ONLY here, so the next "Add another goal"
    /// starts blank while an interrupted flow (a re-created view, a backgrounded app) still resumes.
    private func close() {
        draft.reset()
        onClose()
        dismiss()
    }
}

/// The runway shortcuts on the target-date step. Not a limit — the full date picker sits right below
/// them — just the three answers people actually give when asked "by when?".
enum GoalRunwayPreset: String, CaseIterable, Identifiable {
    case sixWeeks, threeMonths, sixMonths

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sixWeeks:    return "6 weeks"
        case .threeMonths: return "3 months"
        case .sixMonths:   return "6 months"
        }
    }

    /// The date this preset sets, from `now`. Falls back to plain day arithmetic on the (impossible)
    /// nil from `Calendar`, so a preset always produces a date.
    func date(from now: Date) -> Date {
        let cal = Calendar.current
        switch self {
        case .sixWeeks:
            return cal.date(byAdding: .day, value: 42, to: now) ?? now.addingTimeInterval(42 * 24 * 3600)
        case .threeMonths:
            return cal.date(byAdding: .month, value: 3, to: now) ?? now.addingTimeInterval(91 * 24 * 3600)
        case .sixMonths:
            return cal.date(byAdding: .month, value: 6, to: now) ?? now.addingTimeInterval(182 * 24 * 3600)
        }
    }
}
