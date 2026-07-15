import Foundation

/// Background memory upkeep: when the user moves on from a conversation, a CHEAP model distils it into a
/// one-line summary (for cross-conversation recall) plus any durable facts (into `CoachMemory`). Kept in
/// its own file, driven entirely through internal engine APIs (`cheapComplete`, `applySummary`), so it
/// stays merge-clean against upstream and never touches the private key/HTTP internals.
///
/// Cost control: only runs with data consent AND auto-summarise on, only after enough new turns have
/// accrued, and always via the cheap `memoryModel`. Best-effort and silent — a failure never disturbs
/// the chat. Everything stays on-device except the one cheap request to the user's own provider.
extension AICoachEngine {

    /// Minimum new messages since the last summary before spending a cheap-model call.
    private var summarizeThreshold: Int { 4 }

    /// Summarise a conversation the user is leaving, if worthwhile. Fire-and-forget.
    func maybeSummarize(_ conversationID: UUID) {
        guard dataConsent, autoSummarize else { return }
        guard let convo = conversations.first(where: { $0.id == conversationID }) else { return }
        let userTurns = convo.messages.filter { $0.role == .user && !$0.text.isEmpty }.count
        guard userTurns >= 1 else { return }
        let newSince = convo.messages.count - (convo.summarizedCount ?? 0)
        guard newSince >= summarizeThreshold else { return }
        Task { await runSummary(for: conversationID) }
    }

    /// Summarise a conversation now, regardless of the threshold (the settings "Summarise now" action).
    func summarizeNow(_ conversationID: UUID) {
        guard dataConsent else { return }
        Task { await runSummary(for: conversationID) }
    }

    private func runSummary(for id: UUID) async {
        guard let convo = conversations.first(where: { $0.id == id }) else { return }
        let turns = convo.messages.filter { !$0.text.isEmpty }
        guard !turns.isEmpty else { return }
        let transcript = turns
            .map { "\($0.role == .user ? "User" : "Coach"): \($0.text)" }
            .joined(separator: "\n")
        guard let raw = await cheapComplete(system: Self.memorySummarizerSystem,
                                            user: "Conversation transcript:\n\(transcript)") else { return }
        let (summary, facts) = Self.parseMemoryOutput(raw)
        if !summary.isEmpty {
            applySummary(conversationID: id, summary: summary, summarizedCount: convo.messages.count)
        }
        // Distil durable facts into memory; CoachMemory.add handles near-duplicates and the cap.
        for fact in facts { CoachMemory.shared.add(fact) }
    }

    /// Instruction for the cheap summariser: one summary line + distilled durable facts, in a strict,
    /// easy-to-parse shape so a small model stays reliable.
    static let memorySummarizerSystem = """
    You compress a coaching chat into durable memory. Output EXACTLY this format and nothing else:
    SUMMARY: <one or two sentences capturing what mattered in this conversation>
    FACT: <a durable fact about the user worth remembering across chats>
    FACT: <another, if any>
    Only add FACT lines for genuinely durable facts (goals, injuries, constraints, preferences, \
    schedule) — never transient chit-chat or the day's numbers. Emit no FACT lines when there are none.
    """

    /// Parse the strict summariser output into (summary, facts). Lenient about spacing/casing.
    static func parseMemoryOutput(_ raw: String) -> (summary: String, facts: [String]) {
        var summary = ""
        var facts: [String] = []
        for line in raw.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if let r = t.range(of: "SUMMARY:", options: .caseInsensitive) {
                summary = String(t[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            } else if let r = t.range(of: "FACT:", options: .caseInsensitive) {
                let f = String(t[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !f.isEmpty { facts.append(f) }
            }
        }
        return (summary, facts)
    }
}
