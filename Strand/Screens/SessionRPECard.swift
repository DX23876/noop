import SwiftUI
import StrandDesign
#if canImport(UserNotifications)
import UserNotifications
#endif

// MARK: - Whole-session perceived load
//
// This is deliberately a user input. Set-level RPE describes individual lifts; heart-rate Effort
// describes cardiovascular work. Neither is the athlete's answer to "how demanding was the whole
// session?". Asking once, on the session detail, keeps that third signal explicit and reviewable.

struct SessionRPECard: View {
    let startTs: Int
    let sport: String
    let durationS: Double?

    @EnvironmentObject private var repo: Repository
    @State private var saved: SessionRPEEntry?
    @State private var draft = 7.0
    @State private var editing = false
    @State private var saving = false
    @State private var canonicalSessionId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Session load", overline: "Your perception",
                          trailing: saved.flatMap(loadText))
            NoopCard(tint: StrandPalette.metricCyan) {
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    if editing {
                        editor
                    } else if let saved {
                        savedState(saved)
                    } else {
                        emptyState
                    }
                }
            }
        }
        .task(id: startTs) {
            canonicalSessionId = await repo.canonicalTrainingSession(containingStartTs: startTs)?.id
            if let canonicalSessionId, let byId = await repo.sessionRPE(sessionId: canonicalSessionId) {
                saved = byId
            } else {
                saved = await repo.sessionRPE(at: startTs)
            }
            if let saved { draft = saved.rpe }
            if saved == nil, let durationS {
                await SessionRPEReminder.schedule(startTs: startTs, durationS: durationS, sport: sport)
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            Text("How demanding did the whole session feel?")
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
            Text("Rate it from 1 to 10. NOOP multiplies your rating by the session duration and keeps it separate from heart-rate and strength load.")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Rate this session") {
                draft = 7
                editing = true
            }
            .buttonStyle(NoopButtonStyle(.secondary, fullWidth: true))
        }
    }

    private func savedState(_ entry: SessionRPEEntry) -> some View {
        HStack(alignment: .center, spacing: NoopMetrics.space3) {
            VStack(alignment: .leading, spacing: 3) {
                Text(String(localized: "RPE \(rpeNumber(entry.rpe))"))
                    .font(StrandFont.number(26))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(loadExplanation(entry.rpe))
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(ratingTiming(entry))
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer(minLength: 8)
            Button("Edit") {
                draft = entry.rpe
                editing = true
            }
            .buttonStyle(.plain)
            .foregroundStyle(StrandPalette.accent)
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            HStack(alignment: .firstTextBaseline) {
                Text("Whole-session RPE")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                Text(String(localized: "\(rpeNumber(draft)) / 10"))
                    .font(StrandFont.number(22))
                    .foregroundStyle(StrandPalette.metricCyan)
                    .monospacedDigit()
            }
            Slider(value: $draft, in: 1...10, step: 0.5)
                .tint(StrandPalette.metricCyan)
                .accessibilityLabel("Whole-session RPE")
                .accessibilityValue(String(localized: "\(rpeNumber(draft)) out of 10"))
            HStack {
                Text("1")
                Spacer()
                Text("How the complete workout felt")
                Spacer()
                Text("10")
            }
            .font(StrandFont.caption)
            .foregroundStyle(StrandPalette.textTertiary)
            HStack(spacing: NoopMetrics.space2) {
                if saved != nil {
                    Button("Remove") { Task { await remove() } }
                        .buttonStyle(NoopButtonStyle(.secondary, fullWidth: true))
                        .disabled(saving)
                }
                Button("Save rating") { Task { await save() } }
                    .buttonStyle(NoopButtonStyle(.primary, fullWidth: true))
                    .disabled(saving)
            }
        }
    }

    private func loadText(_ entry: SessionRPEEntry) -> String? {
        guard let minutes = durationMinutes else { return nil }
        return String(localized: "\(Int((entry.rpe * minutes).rounded())) AU")
    }

    private func loadExplanation(_ rpe: Double) -> String {
        guard let minutes = durationMinutes else {
            return String(localized: "Rating saved · duration unavailable")
        }
        return String(localized: "RPE \(rpeNumber(rpe)) × \(Int(minutes.rounded())) min · sRPE load")
    }

    private func rpeNumber(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)))
    }

    private var durationMinutes: Double? {
        guard let durationS, durationS > 0 else { return nil }
        return durationS / 60
    }

    @MainActor
    private func save() async {
        saving = true
        if await repo.recordSessionRPE(draft, startTs: startTs, sport: sport,
                                       sessionId: canonicalSessionId) {
            if let canonicalSessionId {
                saved = await repo.sessionRPE(sessionId: canonicalSessionId)
            } else {
                saved = await repo.sessionRPE(at: startTs)
            }
            editing = false
            SessionRPEReminder.cancel(startTs: startTs)
        }
        saving = false
    }

    @MainActor
    private func remove() async {
        saving = true
        if let entry = saved, await repo.deleteSessionRPE(id: entry.id) {
            saved = nil
            editing = false
        }
        saving = false
    }
}

private extension SessionRPECard {
    func ratingTiming(_ entry: SessionRPEEntry) -> String {
        guard let ratedAt = entry.ratedAtTs else { return String(localized: "Rating time unknown") }
        let end = startTs + Int(durationS ?? 0)
        let delayMinutes = Int((Double(ratedAt - end) / 60).rounded())
        if (20...45).contains(delayMinutes) { return String(localized: "Rated about 30 minutes after training") }
        if delayMinutes < 20 { return String(localized: "Rated immediately after training") }
        return String(localized: "Rated later")
    }
}

#if canImport(UserNotifications)
enum SessionRPEReminder {
    static func id(_ startTs: Int) -> String { "session-rpe-reminder-\(startTs)" }

    static func schedule(startTs: Int, durationS: Double, sport: String) async {
        let centre = UNUserNotificationCenter.current()
        let settings = await centre.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            return
        }
        let end = Date(timeIntervalSince1970: TimeInterval(startTs) + durationS)
        let fire = end.addingTimeInterval(30 * 60)
        guard fire > Date() else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "How did the session feel?")
        content.body = String(localized: "Rate \(sport) from 1 to 10 for your Session Load.")
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: fire.timeIntervalSinceNow, repeats: false)
        centre.removePendingNotificationRequests(withIdentifiers: [id(startTs)])
        try? await centre.add(UNNotificationRequest(identifier: id(startTs), content: content, trigger: trigger))
    }

    static func cancel(startTs: Int) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id(startTs)])
    }
}
#else
enum SessionRPEReminder {
    static func schedule(startTs: Int, durationS: Double, sport: String) async {}
    static func cancel(startTs: Int) {}
}
#endif
