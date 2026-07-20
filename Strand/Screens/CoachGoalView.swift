import SwiftUI
import StrandDesign

/// The goal editor — used both from Coach settings and as the (skippable) first-run onboarding.
///
/// Two things it is deliberately careful about:
///   • The safety verdict is shown LIVE as you type, from `GoalSafetyGate` — a pure function, not the
///     model's opinion. A flagged pace asks for a reason and then lets you proceed; it never blocks.
///   • `motivation` is the most personal thing the app holds. It stays on the device unless you
///     explicitly turn on sharing, and the UI says so rather than burying it in a privacy policy.
struct CoachGoalEditorView: View {
    @ObservedObject private var store = CoachGoalStore.shared
    @Environment(\.dismiss) private var dismiss

    /// Onboarding shows a Skip affordance and a warmer intro; settings shows Cancel.
    let isOnboarding: Bool
    /// Called when the sheet closes either way, so onboarding can mark itself as asked.
    var onClose: () -> Void = {}
    /// True when replacing a CLOSED (achieved/abandoned) goal: the form starts blank and Save mints a
    /// brand-new goal with its own id and history, instead of editing the finished one back to life.
    var startsFresh: Bool = false

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

    /// Two-column grid for the goal-type tiles and the motivation chips — no custom flow layout needed.
    private let twoColumns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    /// The profile weight the safety gate normalises against — read once, like the rest of the context.
    private var bodyWeightKg: Double { ProfileStore().weightKg }

    /// The goal as currently typed, so the gates can judge it live.
    private var draft: CoachGoal {
        CoachGoal(kind: kind,
                  title: title,
                  baseline: Double(baselineText.replacingOccurrences(of: ",", with: ".")),
                  target: Double(targetText.replacingOccurrences(of: ",", with: ".")),
                  targetDate: hasTargetDate ? targetDate : nil,
                  motivation: motivation,
                  motivationTags: CoachGoal.MotivationTag.allCases.filter { motivationTags.contains($0) },
                  shareMotivation: shareMotivation)
    }

    private var safety: GoalSafetyGate.Assessment {
        GoalSafetyGate.assess(goal: draft, bodyWeightKg: bodyWeightKg)
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if isOnboarding { introCard }
                    kindCard
                    detailsCard
                    if safety.warning != nil { paceCard }
                    motivationCard
                }
                .padding(16)
            }
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationTitle(isOnboarding ? "Your goal" : "Edit goal")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isOnboarding ? "Skip" : "Cancel") { onClose(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { attemptSave() }.disabled(!canSave)
                }
            }
            .alert("Why this pace?", isPresented: $showReasonPrompt) {
                TextField("e.g. deliberate cut phase", text: $reason)
                Button("Cancel", role: .cancel) {}
                Button("Save anyway") { save(acknowledging: true) }
            } message: {
                // One single literal, not `+`-concatenation: a concatenated argument is a plain String,
                // which hits Text's verbatim initialiser and silently skips localization.
                Text("This is faster than usually recommended. It's your call — tell me why and I'll note it, so I coach you through it instead of arguing with you every week.")
            }
            .onAppear(perform: load)
        }
    }

    // MARK: - Cards

    private var introCard: some View {
        NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            VStack(alignment: .leading, spacing: 6) {
                Text("What are you working towards?")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                // Single literal — see the localization note above.
                Text("With a target and a date I can tell you where you stand, not just how you slept. Entirely optional — everything else works without it.")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Visual goal-type CARDS (8.2 / 8.3) — a tappable icon+label+blurb tile per kind, replacing the old
    /// dropdown so the choice reads as a set of directions, not a form field.
    private var kindCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Goal type").strandOverline()
            LazyVGrid(columns: twoColumns, spacing: 10) {
                ForEach(CoachGoal.Kind.allCases) { k in
                    GoalKindTile(kind: k, selected: kind == k) { kind = k }
                }
            }
            if kind == .weight {
                // Single literal — see the localization note above.
                Text("I'll track your weight and plan your training around it — but I have no nutrition data, and that's where most of weight change is decided. I won't pretend otherwise.")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !kind.isQuantified {
                // Single literal — see the localization note above.
                Text("I can hold this goal and shape your training around it, but I can't measure it from your strap — so I won't invent progress numbers for it.")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var detailsCard: some View {
        NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            VStack(alignment: .leading, spacing: 10) {
                field("Goal", placeholder: placeholderTitle, text: $title)
                if kind.isQuantified {
                    HStack(spacing: 10) {
                        field("From (\(kind.unit))", placeholder: "now", text: $baselineText, numeric: true)
                        field("To (\(kind.unit))", placeholder: "target", text: $targetText, numeric: true)
                    }
                }
                Toggle(isOn: $hasTargetDate) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Target date")
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                        Text("Without one I can't tell you how you're tracking.")
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    }
                }
                .toggleStyle(.switch).tint(StrandPalette.accent)
                if hasTargetDate {
                    DatePicker("Target date", selection: $targetDate, in: Date()..., displayedComponents: .date)
                        .datePickerStyle(.compact)
                        .tint(StrandPalette.accent)
                        .labelsHidden()
                        .accessibilityLabel("Target date")
                }
            }
        }
    }

    /// The live pace verdict. Informational — it explains, it does not gate the Save button. The reason
    /// prompt only appears for the very-aggressive tier, on save.
    private var paceCard: some View {
        NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: safety.verdict == .veryAggressive
                      ? "exclamationmark.triangle.fill" : "info.circle.fill")
                    .foregroundStyle(safety.verdict == .veryAggressive
                                     ? StrandPalette.statusWarning : StrandPalette.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("About that pace").strandOverline()
                    Text(safety.warning ?? "")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var motivationCard: some View {
        NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("What are you really after?").strandOverline()
                    Text("Pick what's driving this — the coach uses it to shape its advice, not just decorate the screen.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    LazyVGrid(columns: twoColumns, spacing: 8) {
                        ForEach(CoachGoal.MotivationTag.allCases) { tag in
                            GoalMotivationChip(tag: tag, selected: motivationTags.contains(tag)) {
                                if motivationTags.contains(tag) { motivationTags.remove(tag) }
                                else { motivationTags.insert(tag) }
                            }
                        }
                    }
                }
                Divider().overlay(StrandPalette.hairline)
                field("Anything more personal? (optional)",
                      placeholder: "the reason you'll remember at 6am", text: $motivation)
                Toggle(isOn: $shareMotivation) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Share this with the coach")
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
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
    }

    // MARK: - Pieces

    @ViewBuilder
    private func field(_ label: String, placeholder: String,
                       text: Binding<String>, numeric: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // `label` is a fixed literal at some call sites ("Goal") and a composed unit string at others
            // ("From (km)"); `.localizedCatalogValue` resolves the former and harmlessly passes the
            // latter through unchanged (#P14).
            Text(label.localizedCatalogValue).strandOverline()
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
                .disableAutocorrection(true)
                #if !os(macOS)
                .keyboardType(numeric ? .decimalPad : .default)
                #endif
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(StrandPalette.surfaceInset,
                            in: RoundedRectangle(cornerRadius: CoachRadius.field, style: .continuous))
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

    // MARK: - Load / save

    private func load() {
        guard !startsFresh, let g = store.goal else { return }
        kind = g.kind
        title = g.title
        baselineText = g.baseline.map { String(format: "%g", $0) } ?? ""
        targetText = g.target.map { String(format: "%g", $0) } ?? ""
        hasTargetDate = g.targetDate != nil
        if let d = g.targetDate { targetDate = d }
        motivation = g.motivation
        motivationTags = Set(g.motivationTags)
        shareMotivation = g.shareMotivation
    }

    /// The very-aggressive tier asks for a reason first. It's a prompt, not a wall: "Save anyway" is
    /// always available once they've said why.
    private func attemptSave() {
        if safety.requiresReason && store.goal?.acknowledgedRisk == nil {
            showReasonPrompt = true
        } else {
            save(acknowledging: false)
        }
    }

    private func save(acknowledging: Bool) {
        // The identity/history-preserving persistence now lives in `CoachGoalStore.commit` (#R12), shared
        // with the guided onboarding flow so the two paths save identically.
        let ack: CoachGoal.RiskAcknowledgement? = acknowledging
            ? CoachGoalRisk.acknowledgement(verdict: safety.verdict.rawValue, reason: reason)
            : nil
        let clearStale = !acknowledging && (safety.verdict == .ok || safety.verdict == .notApplicable)
        store.commit(draft, startsFresh: startsFresh, acknowledgedRisk: ack, clearStaleAck: clearStale)
        onClose()
        dismiss()
    }
}

/// Small shared helper (#R12): builds a pace acknowledgement from a raw reason, so the one-page editor
/// and the guided flow record it identically (a blank reason becomes an honest "No reason given").
enum CoachGoalRisk {
    static func acknowledgement(verdict: String, reason: String) -> CoachGoal.RiskAcknowledgement {
        let why = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return CoachGoal.RiskAcknowledgement(verdict: verdict,
                                             reason: why.isEmpty ? "No reason given" : why,
                                             date: Date())
    }
}

/// A tappable goal-type tile (#R12) — extracted so the one-page editor and the guided onboarding flow
/// show the same visual directions instead of duplicating the layout. Pure over its inputs.
struct GoalKindTile: View {
    let kind: CoachGoal.Kind
    let selected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: kind.icon)
                    .font(.system(size: 20))
                    .foregroundStyle(selected ? StrandPalette.accent : StrandPalette.textSecondary)
                    .accessibilityHidden(true)
                Text(LocalizedStringKey(kind.label))
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                Text(LocalizedStringKey(kind.blurb))
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(selected ? StrandPalette.accent.opacity(0.12) : StrandPalette.surfaceInset))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(selected ? StrandPalette.accent : StrandPalette.hairline,
                              lineWidth: selected ? 1.5 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(LocalizedStringKey(kind.label)))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A tappable motivation chip (#R12) — extracted for the same reason as `GoalKindTile`.
struct GoalMotivationChip: View {
    let tag: CoachGoal.MotivationTag
    let selected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Image(systemName: tag.icon)
                    .font(StrandFont.footnote)
                    .foregroundStyle(selected ? StrandPalette.accent : StrandPalette.textSecondary)
                    .accessibilityHidden(true)
                Text(LocalizedStringKey(tag.label))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(2).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(selected ? StrandPalette.accent.opacity(0.12) : StrandPalette.surfaceInset))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? StrandPalette.accent : StrandPalette.hairline,
                              lineWidth: selected ? 1.5 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(LocalizedStringKey(tag.label)))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
