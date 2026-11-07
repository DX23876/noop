#if os(iOS)
import SwiftUI
import StrandDesign

/// "Why am I seeing this?" for one coach note on Today: what triggered it, what the coach read to write
/// it, where the figures come from, and a way to turn that kind of note off. Everything shown is read
/// from the stored message (its origin, tools and local context), nothing is inferred.
struct ForgeCoachWhySheet: View {
    let entry: ForgeTimeline.Entry
    let message: ChatMessage?
    let onCoachSettings: () -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage(ForgeCoachNotes.Kind.morning.enabledKey) private var morningNotes = true
    @AppStorage(ForgeCoachNotes.Kind.afterWorkout.enabledKey) private var workoutNotes = true
    @AppStorage(ForgeCoachNotes.Kind.evening.enabledKey) private var eveningNotes = true

    private var origin: ForgeTimeline.CoachNote.Origin? {
        if case .coach(let origin) = entry.kind { return origin }
        return nil
    }

    /// The note kinds the new design writes on its own, each with its switch.
    private var noteKind: ForgeCoachNotes.Kind? {
        switch origin {
        case .brief: return .morning
        case .afterWorkout: return .afterWorkout
        case .evening: return .evening
        default: return nil
        }
    }

    private var noteSwitch: Binding<Bool>? {
        switch noteKind {
        case .morning: return $morningNotes
        case .afterWorkout: return $workoutNotes
        case .evening: return $eveningNotes
        case nil: return nil
        }
    }

    private var trigger: String {
        switch origin {
        case .brief: return String(localized: "Your morning note, written once a day after the night has synced. It also asks about yesterday when a planned session is still open.")
        case .checkIn: return String(localized: "Your daily check-in at your usual wake time.")
        case .nudge: return String(localized: "The coach found a real signal in your data, such as a streak, a multi-night trend or a goal date. It stays quiet on ordinary days.")
        case .weeklyReview: return String(localized: "The weekly review, at most once every seven days.")
        case .afterWorkout: return String(localized: "Written once after a workout ended, at most three coach notes a day and never between 22:00 and 07:00.")
        case .evening: return String(localized: "The evening recap, once a day after 19:00, at most three coach notes a day and never between 22:00 and 07:00.")
        case nil: return ""
        }
    }

    /// Tool names as words: "get_metric_history" reads "metric history".
    private var readList: [String] {
        guard let message else { return [] }
        let tools = message.toolsUsed.map {
            $0.replacingOccurrences(of: "get_", with: "").replacingOccurrences(of: "_", with: " ")
        }
        let local = message.localContextUsed.map { $0.rawValue }
        var seen = Set<String>()
        return (tools + local).filter { seen.insert($0).inserted }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    section("Why now", text: trigger)
                    if !readList.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("What the coach read").font(ForgeFont.cardTitle).foregroundStyle(ForgeColor.text)
                            FlowRows(spacing: 6) {
                                ForEach(readList, id: \.self) { item in
                                    Text(item)
                                        .font(.system(.footnote, weight: .medium))
                                        .foregroundStyle(ForgeColor.text)
                                        .padding(.horizontal, 10).padding(.vertical, 4)
                                        .background(Capsule().fill(ForgeColor.fill))
                                }
                            }
                        }
                    }
                    section("Where the figures come from",
                            text: String(localized: "Every number is read on this iPhone. Your coach provider writes the words around them from the data you allowed in Coach settings."))
                    if let kind = noteKind, let noteSwitch {
                        Toggle(isOn: noteSwitch) {
                            Group {
                                switch kind {
                                case .morning: Text("Morning note")
                                case .afterWorkout: Text("Notes after workouts")
                                case .evening: Text("Evening recap")
                                }
                            }
                            .font(.system(.callout, weight: .semibold))
                        }
                        .tint(ForgeColor.accent)
                        .forgeCard(radius: ForgeRadius.card, padding: 14)
                    }
                    Button(action: onCoachSettings) {
                        Label("Coach settings, memory and usage", systemImage: "slider.horizontal.3")
                            .font(.system(.callout, weight: .semibold))
                            .foregroundStyle(ForgeColor.accent)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(Capsule().fill(ForgeColor.fill))
                    }
                    .buttonStyle(.plain)
                }
                .padding(20)
            }
            .background(ForgeColor.canvas.ignoresSafeArea())
            .navigationTitle(Text("Why am I seeing this?"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func section(_ title: LocalizedStringKey, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(ForgeFont.cardTitle).foregroundStyle(ForgeColor.text)
            Text(text).font(ForgeFont.body).foregroundStyle(ForgeColor.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
#endif
