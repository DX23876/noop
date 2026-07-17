import SwiftUI
import StrandDesign

/// The plan book: what the coach suggested, what you agreed to, and what happened.
///
/// This screen is where the consent lives. The coach can only ever propose; every "yes" on this page is
/// a deliberate tap. Nothing here nags — a proposal you ignore just sits there.
struct CoachPlanView: View {
    @EnvironmentObject private var coach: AICoachEngine
    @ObservedObject private var store = CoachPlanStore.shared
    @Environment(\.dismiss) private var dismiss

    /// Assembled once for the swap sheet's consequence maths (async — it reads the workout history).
    @State private var inputs = PlanConsequence.Inputs()
    @State private var swapping: PlanProposal?
    @State private var scheduling: PlanProposal?

    private var today: String { Repository.localDayKey(Date()) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if !store.pending.isEmpty {
                        section("Waiting for your call") {
                            ForEach(store.pending) { p in pendingCard(p) }
                        }
                    }
                    let upcoming = store.commitments(fromDay: today)
                    if !upcoming.isEmpty {
                        section("Agreed") {
                            ForEach(upcoming) { p in commitmentCard(p) }
                        }
                    }
                    let recent = store.proposals.filter {
                        $0.day < today && $0.status.isDecided
                    }.prefix(10)
                    if !recent.isEmpty {
                        section("Recently") {
                            ForEach(Array(recent)) { p in historyRow(p) }
                        }
                    }
                    if store.proposals.isEmpty { emptyState }
                }
                .padding(16)
            }
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationTitle("Your plan")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task { inputs = await coach.planInputs() }
            .sheet(item: $swapping) { p in
                PlanSwapSheet(proposal: p, inputs: inputs)
            }
            .sheet(item: $scheduling) { p in
                PlanTimeSheet(proposal: p)
            }
        }
    }

    // MARK: - Cards

    /// A suggestion, with the three honest answers. "Change" is first-class alongside yes/no — a plan
    /// you had to alter is still a plan you agreed to, and pretending otherwise is how adherence data
    /// turns into a guilt ledger.
    private func pendingCard(_ p: PlanProposal) -> some View {
        NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles").foregroundStyle(StrandPalette.accent)
                        .accessibilityHidden(true)
                    Text(p.summary())
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                    Spacer(minLength: 4)
                    Text(dayLabel(p.day)).strandOverline()
                }
                if !p.rationale.isEmpty {
                    Text(p.rationale)
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    action("Accept", icon: "checkmark", prominent: true) {
                        store.accept(p.id)
                    }
                    action("Change", icon: "arrow.triangle.2.circlepath") { swapping = p }
                    action("Not this one", icon: "xmark") { store.decline(p.id) }
                }
            }
        }
    }

    private func commitmentCard(_ p: PlanProposal) -> some View {
        NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "calendar").foregroundStyle(StrandPalette.accent)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.summary())
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                        if let from = p.swappedFrom {
                            Text("swapped from \(from)")
                                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                        }
                    }
                    Spacer(minLength: 4)
                    Text(dayLabel(p.day)).strandOverline()
                }
                HStack(spacing: 8) {
                    action(p.time == nil ? "Set a time" : "Change time", icon: "clock") { scheduling = p }
                    action("Swap", icon: "arrow.triangle.2.circlepath") { swapping = p }
                }
                HStack(spacing: 8) {
                    action("Done", icon: "checkmark.circle", prominent: true) { store.complete(p.id) }
                    // The one-tap reason. A reason you have to type is a reason that never gets
                    // recorded — and then "didn't train" reads as laziness when it was a sore knee.
                    Menu {
                        ForEach(PlanProposal.SkipReason.allCases, id: \.self) { reason in
                            Button(reason.label) { store.skip(p.id, reason: reason) }
                        }
                    } label: {
                        Label("Didn't happen", systemImage: "xmark.circle")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(StrandPalette.surfaceInset,
                                        in: RoundedRectangle(cornerRadius: CoachRadius.field, style: .continuous))
                    }
                    .accessibilityLabel("Mark as not done, and say why")
                }
            }
        }
    }

    private func historyRow(_ p: PlanProposal) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon(for: p.status))
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(p.summary())
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                Text(statusLine(p))
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer(minLength: 4)
            Text(dayLabel(p.day))
                .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(p.summary()), \(statusLine(p)), \(dayLabel(p.day))")
    }

    private var emptyState: some View {
        NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            VStack(alignment: .leading, spacing: 6) {
                Text("No plan yet")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                // One single literal, not `+`-concatenation: a concatenated argument is a plain String,
                // which hits Text's verbatim initialiser and silently skips localization.
                Text("Ask the coach what to do this week. Anything it suggests lands here for your yes first — nothing gets scheduled behind your back.")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Pieces

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).strandOverline()
            content()
        }
    }

    private func action(_ title: String, icon: String, prominent: Bool = false,
                        run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Label(title, systemImage: icon)
                .font(StrandFont.footnote)
                .foregroundStyle(prominent ? .white : StrandPalette.textSecondary)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(prominent ? StrandPalette.accent : StrandPalette.surfaceInset,
                            in: RoundedRectangle(cornerRadius: CoachRadius.field, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private func icon(for status: PlanProposal.Status) -> String {
        switch status {
        case .completed:      return "checkmark.circle.fill"
        case .skipped:        return "xmark.circle"
        case .declined:       return "hand.thumbsdown"
        case .paused:         return "pause.circle"
        case .modifiedByUser: return "arrow.triangle.2.circlepath"
        case .accepted:       return "calendar"
        case .proposed:       return "sparkles"
        }
    }

    /// Deliberately neutral wording — a skip states its reason, it doesn't editorialise about it.
    private func statusLine(_ p: PlanProposal) -> String {
        switch p.status {
        case .skipped:  return p.skipReason.map { "didn't happen — \($0.label.lowercased())" } ?? "didn't happen"
        case .declined: return "you passed on this one"
        default:        return p.status.rawValue
        }
    }

    private func dayLabel(_ day: String) -> String {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        guard let date = df.date(from: day) else { return day }
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInTomorrow(date) { return "Tomorrow" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        let out = DateFormatter(); out.dateFormat = "EEE d MMM"
        return out.string(from: date)
    }
}

// MARK: - Swap

/// Swapping a session — and seeing what your own history says it costs BEFORE you decide.
///
/// The whole point: this informs, it never blocks. There's no disabled Save, no "are you sure". You get
/// the numbers, then you get to choose.
struct PlanSwapSheet: View {
    let proposal: PlanProposal
    let inputs: PlanConsequence.Inputs

    @ObservedObject private var store = CoachPlanStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var sport = ""
    @State private var intent: PlanProposal.Intent = .moderate

    private var comparison: PlanConsequence.Comparison? {
        let trimmed = sport.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return PlanConsequence.compare(from: proposal.sport, fromEffort: proposal.targetEffort,
                                       to: trimmed, toEffort: nil, inputs: inputs)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Instead of \(proposal.sport)").strandOverline()
                            TextField("e.g. CrossFit", text: $sport)
                                .textFieldStyle(.plain)
                                .font(StrandFont.body)
                                .foregroundStyle(StrandPalette.textPrimary)
                                .padding(.horizontal, 12).padding(.vertical, 9)
                                .background(StrandPalette.surfaceInset,
                                            in: RoundedRectangle(cornerRadius: CoachRadius.field, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: CoachRadius.field, style: .continuous)
                                    .strokeBorder(StrandPalette.hairline, lineWidth: 1))
                                .accessibilityLabel("New activity")
                            Picker("How hard", selection: $intent) {
                                ForEach(PlanProposal.Intent.allCases, id: \.self) { i in
                                    Text(i.label).tag(i)
                                }
                            }
                            .pickerStyle(.segmented)
                            .accessibilityLabel("How hard")
                        }
                    }
                    if let comparison {
                        NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "info.circle.fill")
                                    .foregroundStyle(StrandPalette.accent)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("What your history says").strandOverline()
                                    Text(comparison.sentence())
                                        .font(StrandFont.footnote)
                                        .foregroundStyle(StrandPalette.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationTitle("Swap session")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Swap") {
                        store.swap(proposal.id,
                                   toSport: sport.trimmingCharacters(in: .whitespacesAndNewlines),
                                   intent: intent)
                        dismiss()
                    }
                    .disabled(sport.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { intent = proposal.intent }
        }
    }
}

// MARK: - Time

/// Pinning a session to a time — "10:00 CrossFit". A plan with a time is a plan you keep.
struct PlanTimeSheet: View {
    let proposal: PlanProposal

    @ObservedObject private var store = CoachPlanStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var time = Date()

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(proposal.sport).strandOverline()
                        // `.wheel` is iOS-only; macOS gets the graphical picker. This file is shared, so
                        // it has to compile for both even though the fork ships iOS.
                        DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                            #if os(iOS)
                            .datePickerStyle(.wheel)
                            #endif
                            .labelsHidden()
                            .accessibilityLabel("Session time")
                    }
                }
                if proposal.time != nil {
                    Button("Remove time", role: .destructive) {
                        store.clearTime(proposal.id)
                        dismiss()
                    }
                    .font(StrandFont.footnote)
                }
                Spacer()
            }
            .padding(16)
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationTitle("Set a time")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Set") {
                        // Keep the session's own day — a time alone would silently move it to today.
                        let cal = Calendar.current
                        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
                        let base = df.date(from: proposal.day) ?? Date()
                        let hm = cal.dateComponents([.hour, .minute], from: time)
                        let combined = cal.date(bySettingHour: hm.hour ?? 0, minute: hm.minute ?? 0,
                                                second: 0, of: base)
                        if proposal.status == .proposed {
                            store.accept(proposal.id, at: combined)
                        } else {
                            store.swap(proposal.id, toSport: proposal.sport, at: combined)
                        }
                        dismiss()
                    }
                }
            }
            .onAppear { time = proposal.time ?? Date() }
        }
    }
}
