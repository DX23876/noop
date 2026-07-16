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

    @State private var kind: CoachGoal.Kind = .run
    @State private var title = ""
    @State private var baselineText = ""
    @State private var targetText = ""
    @State private var hasTargetDate = false
    @State private var targetDate = Date().addingTimeInterval(60 * 24 * 3600)
    @State private var motivation = ""
    @State private var shareMotivation = false
    @State private var reason = ""
    @State private var showReasonPrompt = false

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

    private var kindCard: some View {
        NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Goal type").strandOverline()
                Picker("Goal type", selection: $kind) {
                    ForEach(CoachGoal.Kind.allCases) { k in Text(k.label).tag(k) }
                }
                .pickerStyle(.menu)
                .tint(StrandPalette.accent)
                .accessibilityLabel("Goal type")
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
            VStack(alignment: .leading, spacing: 8) {
                field("Why does this matter to you? (optional)",
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
            Text(label).strandOverline()
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
                .accessibilityLabel(label)
        }
    }

    private var placeholderTitle: String {
        switch kind {
        case .run:         return "e.g. Run 5k without stopping"
        case .consistency: return "e.g. Train three times a week"
        case .sleep:       return "e.g. Sleep 7.5 hours a night"
        case .strength:    return "e.g. Get back to full-body strength work"
        case .weight:      return "e.g. Get to 78 kg"
        case .custom:      return "e.g. Feel good on the hills again"
        }
    }

    // MARK: - Load / save

    private func load() {
        guard let g = store.goal else { return }
        kind = g.kind
        title = g.title
        baselineText = g.baseline.map { String(format: "%g", $0) } ?? ""
        targetText = g.target.map { String(format: "%g", $0) } ?? ""
        hasTargetDate = g.targetDate != nil
        if let d = g.targetDate { targetDate = d }
        motivation = g.motivation
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
        var g = draft
        g.status = .active
        // Preserve identity + history across an edit so the change log stays continuous.
        if let existing = store.goal {
            g = CoachGoal(id: existing.id, kind: g.kind, title: g.title,
                          baseline: g.baseline, target: g.target, targetDate: g.targetDate,
                          status: .active, motivation: g.motivation,
                          shareMotivation: g.shareMotivation,
                          acknowledgedRisk: existing.acknowledgedRisk,
                          createdAt: existing.createdAt, history: existing.history)
        }
        if acknowledging {
            let why = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            g.acknowledgedRisk = .init(verdict: safety.verdict.rawValue,
                                       reason: why.isEmpty ? "No reason given" : why,
                                       date: Date())
        } else if safety.verdict == .ok || safety.verdict == .notApplicable {
            // The pace is no longer flagged, so a stale acknowledgement shouldn't linger.
            g.acknowledgedRisk = nil
        }
        g.history.append(.init(date: Date(), what: store.goal == nil ? "Goal set" : "Goal updated"))
        if g.history.count > 20 { g.history.removeFirst(g.history.count - 20) }
        store.goal = g
        onClose()
        dismiss()
    }
}
