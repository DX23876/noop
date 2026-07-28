import Foundation

/// Background memory upkeep: when the user moves on from a conversation, a CHEAP model distils it into a
/// one-line summary (for cross-conversation recall) plus any durable facts (into `CoachMemory`). Kept in
/// its own file, driven entirely through internal engine APIs (`cheapComplete`, `applySummary`), so it
/// stays merge-clean against upstream and never touches the private key/HTTP internals.
///
/// Cost control: only runs with data consent, the separate Memory purpose AND auto-summarise on, only
/// after enough new turns have accrued, and always via the cheap `memoryModel`. Best-effort and silent —
/// a failure never disturbs the chat. Everything stays on-device except the one cheap request to the
/// user's own provider.
extension AICoachEngine {

    /// What a manual "Summarise now" actually did, so the settings card can say so instead of looking
    /// like a button that does nothing. `alreadyUpToDate` is the common repeat-tap case.
    enum SummarizeOutcome: Equatable {
        case started
        case alreadyUpToDate
        case nothingToSummarize
        case noConsent
    }

    /// Minimum new messages since the last summary before spending a cheap-model call.
    private var summarizeThreshold: Int { 4 }

    /// Summarise a conversation the user is leaving, if worthwhile. Fire-and-forget.
    func maybeSummarize(_ conversationID: UUID) {
        guard memoryContextAllowed, autoSummarize else { return }
        guard let convo = conversations.first(where: { $0.id == conversationID }) else { return }
        let userTurns = convo.messages.filter { $0.role == .user && !$0.text.isEmpty }.count
        guard userTurns >= 1 else { return }
        guard Self.newMessageCount(in: convo) >= summarizeThreshold else { return }
        Task { await runSummary(for: conversationID) }
    }

    /// Summarise a conversation now, ignoring the auto-threshold — but NOT ignoring the watermark.
    ///
    /// Re-running this over an already-processed chat used to re-send the WHOLE transcript, so the cheap
    /// model re-emitted the same durable facts in slightly different words and `CoachMemory` stacked them
    /// as new entries. A chat with nothing new since its last summary is now a no-op that reports itself
    /// (`.alreadyUpToDate`), which is also what makes repeat taps free rather than merely harmless.
    @discardableResult
    func summarizeNow(_ conversationID: UUID) -> SummarizeOutcome {
        guard memoryContextAllowed else { return .noConsent }
        guard let convo = conversations.first(where: { $0.id == conversationID }) else {
            return .nothingToSummarize
        }
        guard convo.messages.contains(where: { !$0.text.isEmpty }) else { return .nothingToSummarize }
        guard Self.newMessageCount(in: convo) > 0 else { return .alreadyUpToDate }
        Task { await runSummary(for: conversationID) }
        return .started
    }

    /// Messages that have accrued since this conversation was last summarised. Pure and static so the
    /// watermark rule can be pinned by a test without an engine.
    static func newMessageCount(in convo: CoachConversation) -> Int {
        max(0, convo.messages.count - (convo.summarizedCount ?? 0))
    }

    /// The slice of a conversation that still needs distilling — everything after the watermark. A chat
    /// summarised at message 12 sends messages 13+ only, so no already-distilled turn can produce a
    /// second copy of the same fact.
    static func unsummarizedTail(of convo: CoachConversation) -> [ChatMessage] {
        let done = min(max(0, convo.summarizedCount ?? 0), convo.messages.count)
        return Array(convo.messages.dropFirst(done)).filter { !$0.text.isEmpty }
    }

    private func runSummary(for id: UUID) async {
        guard let convo = conversations.first(where: { $0.id == id }) else { return }
        let turns = Self.unsummarizedTail(of: convo)
        guard !turns.isEmpty else { return }
        let transcript = turns
            .map { "\($0.role == .user ? "User" : "Coach"): \($0.text)" }
            .joined(separator: "\n")
        // The prior summary rides along as CONTEXT (so the new summary still describes the whole thread)
        // while the transcript stays the new turns only (so facts are never re-distilled).
        var user = ""
        if let prior = convo.summary, !prior.isEmpty {
            user += "Summary of this conversation so far:\n\(prior)\n\n"
            user += "New messages since then:\n\(transcript)"
        } else {
            user += "Conversation transcript:\n\(transcript)"
        }
        guard let raw = await cheapComplete(system: Self.memorySummarizerSystem, user: user) else { return }
        let (summary, facts) = Self.parseMemoryOutput(raw)
        // Advance the watermark even when the model returned no summary line: the turns WERE processed,
        // and leaving the watermark behind is exactly what made the next run re-distil them.
        applySummary(conversationID: id, summary: summary, summarizedCount: convo.messages.count)
        // Distil durable facts into memory; CoachMemory.add handles near-duplicates and the cap.
        for fact in facts {
            let category = CoachMemory.inferredCategory(for: fact)
            CoachMemory.shared.add(fact,
                                   category: category,
                                   source: .conversationSummary,
                                   referenceID: id.uuidString)
        }
    }

    /// Instruction for the cheap summariser: one summary line + distilled durable facts, in a strict,
    /// easy-to-parse shape so a small model stays reliable.
    static let memorySummarizerSystem = """
    You compress a coaching chat into durable memory. Output EXACTLY this format and nothing else:
    SUMMARY: <one or two sentences capturing what mattered in this conversation>
    FACT: <a durable fact about the user worth remembering across chats>
    FACT: <another, if any>
    Only add FACT lines for genuinely durable facts (goals, injuries, constraints, preferences, \
    schedule) — never transient chit-chat or the day's numbers. Emit no FACT lines when there are none. \
    When a summary of the conversation so far is given, it is context: SUMMARY must cover the whole \
    thread, but emit FACT lines ONLY for the new messages, never restating a fact from that summary.
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
