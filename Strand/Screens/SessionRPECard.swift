import SwiftUI
import StrandDesign
import StrandCore
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
            await repo.refreshSessionRatingReminders()
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
        guard let load = entry.load(durationS: durationS) else { return nil }
        return String(localized: "\(Int(load.rounded())) AU")
    }

    private func loadExplanation(_ rpe: Double) -> String {
        guard let minutes = durationMinutes else {
            return String(localized: "Rating saved · duration unavailable")
        }
        return String(localized: "RPE \(rpeNumber(rpe)) × \(minutes.formatted(.number.precision(.fractionLength(0...2)))) min · sRPE load")
    }

    private func rpeNumber(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)))
    }

    private var durationMinutes: Double? {
        SessionRPEEntry.durationMinutes(durationS)
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
        switch entry.timing(durationS: durationS) {
        case .unknown: return String(localized: "Rating time unknown")
        case .about30Minutes: return String(localized: "Rated about 30 minutes after training")
        case .immediately: return String(localized: "Rated immediately after training")
        case .later: return String(localized: "Rated later")
        }
    }
}

#if canImport(UserNotifications)
enum SessionRPEReminder {
    static func synchronize(_ candidates: [SessionRatingReminders.Candidate], now: Int) async {
        let centre = UNUserNotificationCenter.current()
        let pending = await centre.pendingNotificationRequests()
        let allowed = Set(candidates.map(\.id))
        centre.removePendingNotificationRequests(withIdentifiers: pending.filter {
            $0.identifier.hasPrefix("session-rpe-reminder-") && !allowed.contains($0.identifier)
        }.map(\.identifier))
        let settings = await centre.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        for candidate in candidates {
            let content = UNMutableNotificationContent()
            let sport = candidate.sport
            content.title = String(localized: "How did the session feel?")
            content.body = String(localized: "Rate \(sport) from 1 to 10 for your Session Load.")
            content.sound = .default
            content.userInfo = ["sessionRatingStartTs": candidate.startTs]
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: Double(max(1, candidate.fireTs - now)), repeats: false)
            try? await centre.add(UNNotificationRequest(identifier: candidate.id, content: content, trigger: trigger))
        }
    }

    static func cancel(startTs: Int) {
        Task {
            let centre = UNUserNotificationCenter.current()
            let pending = await centre.pendingNotificationRequests()
            let ids = pending.filter {
                ($0.content.userInfo["sessionRatingStartTs"] as? Int) == startTs
                    || $0.identifier == "session-rpe-reminder-\(startTs)"
            }.map(\.identifier)
            centre.removePendingNotificationRequests(withIdentifiers: ids)
        }
    }
}
#else
enum SessionRPEReminder {
    static func synchronize(_ candidates: [SessionRatingReminders.Candidate], now: Int) async {}
    static func cancel(startTs: Int) {}
}
#endif
