import SwiftUI
import StrandDesign

/// The GUIDED goal-onboarding flow (#R12): one question at a time — welcome → type → details → why →
/// confirm — instead of the one-page editor's single wall of fields. It's an ALTERNATIVE to that editor,
/// not a replacement: the quick one-page path stays for edits and for anyone who'd rather fill it all in
/// at once. Re-startable at any time from the goal surface. Saves through the same
/// `CoachGoalStore.commit` the editor uses, so the two paths persist identically, and shows the same live
/// pace safety verdict (`GoalSafetyGate`) on the confirm step.
struct CoachGoalOnboardingFlow: View {
    @ObservedObject private var store = CoachGoalStore.shared
    @Environment(\.dismiss) private var dismiss

    /// Called when the flow closes either way (finished or skipped), so first-run onboarding can mark
    /// itself as asked.
    var onClose: () -> Void = {}

    private enum Step: Int, CaseIterable {
        case welcome, type, details, why, confirm

        var title: LocalizedStringKey {
            switch self {
            case .welcome: return "Let's set a goal"
            case .type:    return "What kind of goal?"
            case .details: return "The details"
            case .why:     return "Why does it matter?"
            case .confirm: return "Ready?"
            }
        }
    }

    @State private var step: Step = .welcome

    // Same draft fields as the one-page editor.
    @State private var kind: CoachGoal.Kind = .run
    @State private var title = ""
    @State private var baselineText = ""
    @State private var targetText = ""
    @State private var hasTargetDate = false
    @State private var targetDate = Date().addingTimeInterval(60 * 24 * 3600)
    @State private var motivation = ""
    @State private var motivationTags: Set<CoachGoal.MotivationTag> = []
    @State private var shareMotivation = false
    @State private var reason = ""
    @State private var showReasonPrompt = false
    /// The other active goal of the picked kind (#R-multi-goal), offered to replace rather than silently
    /// overwritten or silently refused — same gate chain the quick editor uses.
    @State private var replaceCandidateId: UUID?
    @State private var showReplaceConfirm = false
    @State private var showLimitReached = false

    /// Kinds that already have an active goal — shown as a note under the type picker so the collision is
    /// visible before confirming, not just at the end.
    private var kindAlreadyActive: Bool { store.activeGoal(for: kind) != nil }

    private let twoColumns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
    private var bodyWeightKg: Double { ProfileStore().weightKg }

    private var draft: CoachGoal {
        CoachGoal(kind: kind, title: title,
                  baseline: Double(baselineText.replacingOccurrences(of: ",", with: ".")),
                  target: Double(targetText.replacingOccurrences(of: ",", with: ".")),
                  targetDate: hasTargetDate ? targetDate : nil,
                  motivation: motivation,
                  motivationTags: CoachGoal.MotivationTag.allCases.filter { motivationTags.contains($0) },
                  shareMotivation: shareMotivation)
    }

    private var safety: GoalSafetyGate.Assessment { GoalSafetyGate.assess(goal: draft, bodyWeightKg: bodyWeightKg) }

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Whether the current step lets the user move on. Only "details" gates (it needs a title); every
    /// other step is a free choice or optional.
    private var canAdvance: Bool {
        step != .details || !trimmedTitle.isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                progressBar
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(step.title).font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
                        content
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                footer
            }
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip") { onClose(); dismiss() }
                }
            }
            .alert("Why this pace?", isPresented: $showReasonPrompt) {
                TextField("e.g. deliberate cut phase", text: $reason)
                Button("Cancel", role: .cancel) {}
                Button("Save anyway") { commit(acknowledging: true) }
            } message: {
                Text("This is faster than usually recommended. It's your call — tell me why and I'll note it, so I coach you through it instead of arguing with you every week.")
            }
            .confirmationDialog("Replace your existing goal?", isPresented: $showReplaceConfirm, titleVisibility: .visible) {
                Button("Replace it") { proceedPastLimitCheck() }
                Button("Cancel", role: .cancel) { replaceCandidateId = nil }
            } message: {
                Text("You already have an active \(kind.label.localizedCatalogValue) goal. Replacing it closes that one out — its story stays in your history.")
            }
            .alert("You're at the limit", isPresented: $showLimitReached) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("You already have \(CoachGoalStore.maxActiveGoals) active goals — set one aside or close one out before adding another.")
            }
        }
    }

    // MARK: - Chrome

    private var progressBar: some View {
        let fraction = Double(step.rawValue + 1) / Double(Step.allCases.count)
        return ProgressView(value: fraction)
            .tint(StrandPalette.accent)
            .padding(.horizontal, 16).padding(.top, 8)
            .accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count)")
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if step != .welcome {
                Button("Back") { withAnimation(StrandMotion.fade) { goBack() } }
                    .buttonStyle(NoopButtonStyle(.secondary))
            }
            Spacer(minLength: 0)
            if step == .confirm {
                NoopButton("Set my goal", systemImage: "checkmark", kind: .primary) { attemptCommit() }
            } else {
                NoopButton(step == .welcome ? "Get started" : "Next",
                           systemImage: "arrow.right", kind: .primary) {
                    withAnimation(StrandMotion.fade) { goNext() }
                }
                .disabled(!canAdvance)
            }
        }
        .padding(16)
        .background(.ultraThinMaterial)
    }

    // MARK: - Steps

    @ViewBuilder
    private var content: some View {
        switch step {
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
                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var typeStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: twoColumns, spacing: 10) {
                ForEach(CoachGoal.Kind.allCases) { k in
                    GoalKindTile(kind: k, selected: kind == k) { kind = k }
                }
            }
            if kindAlreadyActive {
                stepNote("You already have an active \(kind.label.localizedCatalogValue) goal — continuing will offer to replace it.")
            } else if kind == .weight {
                stepNote("I'll track your weight and plan your training around it — but I have no nutrition data, and that's where most of weight change is decided. I won't pretend otherwise.")
            } else if !kind.isQuantified {
                stepNote("I can hold this goal and shape your training around it, but I can't measure it from your strap — so I won't invent progress numbers for it.")
            }
        }
    }

    private var detailsStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            field("Goal", placeholder: placeholderTitle, text: $title)
            // "Next" stays disabled until this has a name (`canAdvance`) — on `.custom` it's the ONLY
            // field on this step, so an empty title otherwise reads as the flow silently refusing to
            // move, not as something the user needs to do. Say it plainly instead.
            if trimmedTitle.isEmpty {
                stepNote("Give it a name to continue.")
            }
            if kind.isQuantified {
                HStack(spacing: 10) {
                    field("From (\(kind.unit))", placeholder: "now", text: $baselineText, numeric: true)
                    field("To (\(kind.unit))", placeholder: "target", text: $targetText, numeric: true)
                }
            }
            Toggle(isOn: $hasTargetDate) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Target date").font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                    Text("Without one I can't tell you how you're tracking.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                }
            }
            .toggleStyle(.switch).tint(StrandPalette.accent)
            if hasTargetDate {
                DatePicker("Target date", selection: $targetDate, in: Date()..., displayedComponents: .date)
                    .datePickerStyle(.compact).tint(StrandPalette.accent).labelsHidden()
                    .accessibilityLabel("Target date")
            }
        }
    }

    private var whyStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pick what's driving this — the coach uses it to shape its advice, not just decorate the screen.")
                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: twoColumns, spacing: 8) {
                ForEach(CoachGoal.MotivationTag.allCases) { tag in
                    GoalMotivationChip(tag: tag, selected: motivationTags.contains(tag)) {
                        if motivationTags.contains(tag) { motivationTags.remove(tag) }
                        else { motivationTags.insert(tag) }
                    }
                }
            }
            Divider().overlay(StrandPalette.hairline)
            field("Anything more personal? (optional)",
                  placeholder: "the reason you'll remember at 6am", text: $motivation)
            Toggle(isOn: $shareMotivation) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Share this with the coach").font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                    Text(shareMotivation
                         ? "Sent to your AI provider along with the rest of your context."
                         : "Stays on this device. The coach won't see it.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch).tint(StrandPalette.accent)
            .disabled(motivation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var confirmStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Image(systemName: kind.icon).foregroundStyle(StrandPalette.accent).accessibilityHidden(true)
                        Text(trimmedTitle.isEmpty ? String(localized: "Your goal") : trimmedTitle)
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                    }
                    Text(confirmSummary)
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
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
    }

    private var confirmSummary: String {
        var parts: [String] = [String(localized: "\(kind.label.localizedCatalogValue) goal")]
        if kind.isQuantified, let target = Double(targetText.replacingOccurrences(of: ",", with: ".")) {
            parts.append(String(format: "target %g %@", target, kind.unit))
        }
        if hasTargetDate {
            parts.append(String(localized: "by \(targetDate.formatted(date: .abbreviated, time: .omitted))"))
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
        switch kind {
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

    private func goNext() {
        if let next = Step(rawValue: step.rawValue + 1) { step = next }
    }

    private func goBack() {
        if let prev = Step(rawValue: step.rawValue - 1) { step = prev }
    }

    /// The gate chain (#R-multi-goal), same order as the quick editor's `attemptSave`: a kind collision or
    /// the active-goal ceiling first, then the pace-reason prompt.
    private func attemptCommit() {
        if let limit = store.canAdd(kind: kind) {
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
            ? CoachGoalRisk.acknowledgement(verdict: safety.verdict.rawValue, reason: reason)
            : nil
        let clearStale = !acknowledging && (safety.verdict == .ok || safety.verdict == .notApplicable)
        // The guided flow always ADDS a new goal (#R-multi-goal) — never edits one in place, that's the
        // quick editor's job — replacing a same-kind collision when the user chose to at the gate above.
        store.commit(draft, editingId: nil, replacing: replaceCandidateId, acknowledgedRisk: ack, clearStaleAck: clearStale)
        onClose()
        dismiss()
    }
}
