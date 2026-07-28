import Foundation
import Combine
import SemanticMemory
import WhoopStore

enum CoachSemanticRetrievalMode: String {
    case semantic
    case keywordFallback
    case unavailable
}

struct CoachSemanticRetrieval {
    let context: String
    let mode: CoachSemanticRetrievalMode
}

/// A non-blocking race gate. Structured task groups wait for cancelled children to actually finish,
/// which would defeat the 2.5-second fallback when a C inference call cannot observe cancellation.
private actor SemanticSearchRace {
    private var continuation: CheckedContinuation<[SemanticHit]?, Never>?
    private var resolved = false
    private var resolvedValue: [SemanticHit]?

    func wait() async -> [SemanticHit]? {
        if resolved { return resolvedValue }
        return await withCheckedContinuation { continuation = $0 }
    }

    func resolve(_ value: [SemanticHit]?) {
        guard !resolved else { return }
        resolved = true
        resolvedValue = value
        continuation?.resume(returning: value)
        continuation = nil
    }
}

/// App-facing owner of the rebuildable semantic index. The canonical text stays in CoachMemory,
/// conversations and the journal database; this object only stores source metadata and Float16 vectors
/// in coach-semantic.sqlite. Creating the singleton never loads the bundled model.
@MainActor
final class CoachSemanticMemory: ObservableObject, SemanticMemoryCoordinator {
    static let shared = CoachSemanticMemory()

    static let enabledKey = "coach.semanticMemory.enabled"
    private static let lastForegroundCatchUpKey = "coach.semanticMemory.lastForegroundCatchUp"
    private static let lastRunStateKey = "lastRunAt"
    private static let lastErrorStateKey = "lastError"
    private static let indexedKinds = Set(SemanticSourceKind.allCases)

    @Published private(set) var status = SemanticIndexStatus(
        modelID: "nomic-embed-text-v2-moe-q4_k_m",
        indexedDocuments: 0,
        pendingDocuments: 0,
        byteSize: 0,
        lastRunAt: nil,
        lastError: nil,
        isModelLoaded: false
    )
    @Published private(set) var lastRetrievalMode: CoachSemanticRetrievalMode = .unavailable
    @Published private(set) var selfTestSummary: String?
    @Published private(set) var isIndexing = false
    @Published private(set) var isManualIndexing = false

    var semanticIndexStatus: SemanticIndexStatus { status }

    var isEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: Self.enabledKey) == nil
                ? true
                : UserDefaults.standard.bool(forKey: Self.enabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            if !newValue { Task { await unload() } }
            objectWillChange.send()
        }
    }

    private let store: SemanticIndexStore?
    private let provider: (any TextEmbeddingProvider)?
    private var liveDocuments: [String: SemanticDocument] = [:]
    private var activeWork: Task<Void, Never>?
    private var indexingActivityCount = 0

    private init() {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let directory = base.appendingPathComponent("com.noopapp.noop", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try? SemanticIndexStore(path: directory
            .appendingPathComponent("coach-semantic.sqlite").path)

        #if os(iOS)
        provider = NomicTextEmbeddingProvider()
        #else
        provider = nil
        #endif
        Task { await refreshStatus() }
    }

    func enqueueSemanticDocuments(_ documents: [SemanticDocument]) async {
        guard let store else { return }
        try? await store.enqueue(documents)
        await refreshStatus()
    }

    func purgeSemanticScopes(_ scopes: Set<SemanticConsentScope>) async {
        guard let store else { return }
        try? await store.remove(scopes: scopes)
        liveDocuments = liveDocuments.filter { !scopes.contains($0.value.consentScope) }
        await refreshStatus()
    }

    /// The scopes are derived from the same coarse privacy choices that gate tools and prompt context.
    /// The master consent is checked by the caller before this method is reached.
    static func allowedScopes(for consent: ToolConsent) -> Set<SemanticConsentScope> {
        var scopes: Set<SemanticConsentScope> = []
        if consent.enabled.contains(.memory) { scopes.insert(.memory) }
        if consent.enabled.contains(.logs) { scopes.insert(.personalLogs) }
        if consent.enabled.contains(.sensitiveLogs) { scopes.insert(.sensitiveLogs) }
        if consent.enabled.contains(.patterns) { scopes.insert(.patterns) }
        return scopes
    }

    /// Reconcile canonical sources into the queue without loading Nomic. Missing sources and revoked
    /// scopes are removed before any future search can observe them.
    func reconcile(conversations: [CoachConversation],
                   journalEntries: [JournalEntry],
                   allowedScopes: Set<SemanticConsentScope>) async {
        guard let store else { return }
        guard isEnabled, CoachFeaturePrefs.isEnabled, !allowedScopes.isEmpty else {
            try? await store.remove(scopes: Set(SemanticConsentScope.allCases).subtracting(allowedScopes))
            if allowedScopes.isEmpty { try? await store.clear() }
            liveDocuments = [:]
            await unload()
            await refreshStatus()
            return
        }

        let documents = Self.documents(
            facts: CoachMemory.shared.facts,
            conversations: conversations,
            journalEntries: journalEntries,
            proposals: CoachPlanStore.shared.proposals,
            allowedScopes: allowedScopes
        )
        liveDocuments = Dictionary(documents.map { ($0.documentID, $0) },
                                   uniquingKeysWith: { first, _ in first })
        do {
            try await store.remove(scopes: Set(SemanticConsentScope.allCases).subtracting(allowedScopes))
            try await store.enqueue(documents)
            try await store.removeDocuments(notIn: Set(liveDocuments.keys),
                                              sourceKinds: Self.indexedKinds)
            if let provider {
                try await store.invalidate(modelID: provider.modelID, dimensions: provider.dimensions)
            }
            try await store.setState(nil, for: Self.lastErrorStateKey)
        } catch {
            try? await store.setState(error.localizedDescription, for: Self.lastErrorStateKey)
        }
        await refreshStatus()
    }

    /// Immediate queue update for remember/edit/forget. This deliberately stops after SQLite metadata;
    /// it never prepares the model just because a fact changed.
    func memoryFactsChanged(_ facts: [CoachMemory.MemoryFact]) async {
        guard let store else { return }
        let allowed = UserDefaults.standard.bool(forKey: "ai.dataConsent")
            && ToolConsent.load().enabled.contains(.memory)
        guard allowed, isEnabled, CoachFeaturePrefs.isEnabled else {
            try? await store.removeDocuments(notIn: [], sourceKinds: [.memoryFact])
            liveDocuments = liveDocuments.filter { $0.value.sourceKind != .memoryFact }
            await refreshStatus()
            return
        }
        let changed = Self.memoryDocuments(facts)
        liveDocuments = liveDocuments.filter { $0.value.sourceKind != .memoryFact }
        for document in changed { liveDocuments[document.documentID] = document }
        try? await store.enqueue(changed)
        try? await store.removeDocuments(notIn: Set(changed.map(\.documentID)),
                                         sourceKinds: [.memoryFact])
        await refreshStatus()
    }

    /// Queue-only journal refresh used after a native answer is written or removed. The caller passes
    /// the merged canonical journal, so deleting a native override correctly reveals an imported row
    /// when one exists instead of blindly deleting that source.
    func journalEntriesChanged(_ entries: [JournalEntry]) async {
        guard let store else { return }
        let consent = ToolConsent.load()
        let masterAllowed = UserDefaults.standard.bool(forKey: "ai.dataConsent")
        let scopes = masterAllowed ? Self.allowedScopes(for: consent) : []
        let allowedJournalScopes = scopes.intersection([.personalLogs, .sensitiveLogs])
        let kinds: Set<SemanticSourceKind> = [.journalQuestion, .journalNote]
        guard !allowedJournalScopes.isEmpty, isEnabled, CoachFeaturePrefs.isEnabled else {
            try? await store.removeDocuments(notIn: [], sourceKinds: kinds)
            liveDocuments = liveDocuments.filter { !kinds.contains($0.value.sourceKind) }
            await refreshStatus()
            return
        }
        let changed = Self.documents(facts: [],
                                     conversations: [],
                                     journalEntries: entries,
                                     proposals: [],
                                     allowedScopes: allowedJournalScopes)
        liveDocuments = liveDocuments.filter { !kinds.contains($0.value.sourceKind) }
        for document in changed { liveDocuments[document.documentID] = document }
        try? await store.enqueue(changed)
        try? await store.removeDocuments(notIn: Set(changed.map(\.documentID)),
                                         sourceKinds: kinds)
        await refreshStatus()
    }

    /// Same no-model queue update for chat titles, summaries and the user's own turns. Assistant turns
    /// are never passed into `documents`, so they cannot accidentally enter the semantic index.
    func conversationsChanged(_ conversations: [CoachConversation]) async {
        guard let store else { return }
        let allowed = UserDefaults.standard.bool(forKey: "ai.dataConsent")
            && ToolConsent.load().enabled.contains(.memory)
        let kinds: Set<SemanticSourceKind> = [.conversationTitle, .conversationSummary, .userMessage]
        guard allowed, isEnabled, CoachFeaturePrefs.isEnabled else {
            try? await store.removeDocuments(notIn: [], sourceKinds: kinds)
            liveDocuments = liveDocuments.filter { !kinds.contains($0.value.sourceKind) }
            await refreshStatus()
            return
        }
        let changed = Self.documents(facts: [],
                                     conversations: conversations,
                                     journalEntries: [],
                                     proposals: [],
                                     allowedScopes: [.memory])
        liveDocuments = liveDocuments.filter { !kinds.contains($0.value.sourceKind) }
        for document in changed { liveDocuments[document.documentID] = document }
        try? await store.enqueue(changed)
        try? await store.removeDocuments(notIn: Set(changed.map(\.documentID)),
                                         sourceKinds: kinds)
        await refreshStatus()
    }

    /// Queue-only update for recommendation outcomes and derived habit hypotheses. Rejections,
    /// non-completion and the three post-completion effect choices remain distinct in the source text.
    /// As with journal/chat changes, this method never prepares or loads the embedding model.
    func recommendationsChanged(_ proposals: [PlanProposal]) async {
        guard let store else { return }
        let allowed = UserDefaults.standard.bool(forKey: "ai.dataConsent")
            && ToolConsent.load().enabled.contains(.patterns)
        let kinds: Set<SemanticSourceKind> = [.recommendationFeedback, .habitHypothesis]
        guard allowed, isEnabled, CoachFeaturePrefs.isEnabled else {
            try? await store.removeDocuments(notIn: [], sourceKinds: kinds)
            liveDocuments = liveDocuments.filter { !kinds.contains($0.value.sourceKind) }
            await refreshStatus()
            return
        }
        let changed = Self.documents(facts: [],
                                     conversations: [],
                                     journalEntries: [],
                                     proposals: proposals,
                                     allowedScopes: [.patterns])
        liveDocuments = liveDocuments.filter { !kinds.contains($0.value.sourceKind) }
        for document in changed { liveDocuments[document.documentID] = document }
        try? await store.enqueue(changed)
        try? await store.removeDocuments(notIn: Set(changed.map(\.documentID)),
                                         sourceKinds: kinds)
        await refreshStatus()
    }

    /// Coach-open prewarm. Indexing starts asynchronously and never gates navigation or the composer.
    func prewarm(conversations: [CoachConversation],
                 journalEntries: [JournalEntry],
                 allowedScopes: Set<SemanticConsentScope>) async {
        await reconcile(conversations: conversations,
                        journalEntries: journalEntries,
                        allowedScopes: allowedScopes)
        guard provider != nil, isEnabled, CoachFeaturePrefs.isEnabled else { return }
        activeWork?.cancel()
        activeWork = Task { [weak self] in
            guard let self else { return }
            await self.processPending(limit: 48)
        }
    }

    /// Indexes the high-priority backlog, embeds the question and fuses semantic with exact keyword
    /// ranking. If the model misses the 2.5-second turn budget, the caller gets keyword retrieval now
    /// while the warm-up continues for the next question.
    func retrieve(question: String,
                  conversations: [CoachConversation],
                  journalEntries: [JournalEntry],
                  allowedScopes: Set<SemanticConsentScope>) async -> CoachSemanticRetrieval {
        await reconcile(conversations: conversations,
                        journalEntries: journalEntries,
                        allowedScopes: allowedScopes)
        let lexical = Self.lexicalHits(question: question,
                                       documents: Array(liveDocuments.values),
                                       allowedScopes: allowedScopes)
        guard isEnabled, CoachFeaturePrefs.isEnabled, let provider, let store else {
            return finish(handoffContext(from: Array(lexical.prefix(8)),
                                         requestedScopes: allowedScopes),
                          mode: lexical.isEmpty ? .unavailable : .keywordFallback)
        }

        let race = SemanticSearchRace()
        Task { [weak self] in
                guard let self else {
                    await race.resolve(nil)
                    return
                }
                await self.processPending(limit: 64)
                do {
                    let vector = try await provider.embedQuery(question)
                    let hits = try await store.search(vector: vector,
                                                      allowedScopes: allowedScopes,
                                                      limit: 32)
                    await race.resolve(hits)
                } catch {
                    try? await store.setState(error.localizedDescription,
                                              for: Self.lastErrorStateKey)
                    await race.resolve(nil)
                }
        }
        Task {
            try? await Task.sleep(for: .milliseconds(2_500))
            await race.resolve(nil)
        }
        let semantic = await race.wait()

        guard let semantic else {
            await refreshStatus()
            return finish(handoffContext(from: Array(lexical.prefix(8)),
                                         requestedScopes: allowedScopes),
                          mode: lexical.isEmpty ? .unavailable : .keywordFallback)
        }
        let fused = SemanticRanking.fuse(semantic: semantic,
                                         lexical: lexical,
                                         limit: 8)
        await refreshStatus()
        return finish(handoffContext(from: fused, requestedScopes: allowedScopes),
                      mode: .semantic)
    }

    /// Used by a delivered BGProcessingTask and the foreground 24-hour catch-up. Each row is committed
    /// independently, so expiration can cancel between rows without leaving a half-written batch.
    func performMaintenance(conversations: [CoachConversation],
                            journalEntries: [JournalEntry],
                            allowedScopes: Set<SemanticConsentScope>,
                            limit: Int) async {
        await reconcile(conversations: conversations,
                        journalEntries: journalEntries,
                        allowedScopes: allowedScopes)
        await processPending(limit: limit)
    }

    func foregroundCatchUpIsDue(now: Date = Date()) -> Bool {
        let last = UserDefaults.standard.object(forKey: Self.lastForegroundCatchUpKey) as? Date
        guard let last else {
            // A fresh install must not load Nomic during ordinary startup. Start the 24-hour clock now;
            // Coach-open indexing remains available immediately.
            UserDefaults.standard.set(now, forKey: Self.lastForegroundCatchUpKey)
            return false
        }
        return now.timeIntervalSince(last) >= 86_400
    }

    func markForegroundCatchUp(now: Date = Date()) {
        UserDefaults.standard.set(now, forKey: Self.lastForegroundCatchUpKey)
    }

    /// Starts a user-requested foreground build that keeps taking small, cancellable batches until the
    /// current queue is empty. Canonical sources must be reconciled immediately before this is called.
    func startManualIndexing() {
        guard isEnabled, CoachFeaturePrefs.isEnabled, provider != nil else { return }
        activeWork?.cancel()
        activeWork = Task { [weak self] in
            guard let self else { return }
            await self.runManualIndexing()
        }
    }

    func cancelManualIndexing() {
        guard isManualIndexing else { return }
        activeWork?.cancel()
        activeWork = nil
        isManualIndexing = false
    }

    func rebuild() async {
        guard let store else { return }
        activeWork?.cancel()
        try? await store.clear()
        if !liveDocuments.isEmpty { try? await store.enqueue(Array(liveDocuments.values)) }
        await refreshStatus()
        startManualIndexing()
    }

    func deleteIndex() async {
        activeWork?.cancel()
        activeWork = nil
        if let store { try? await store.clear() }
        await unload()
        await refreshStatus()
    }

    func runModelSelfTest() async {
        #if os(iOS)
        guard isEnabled, CoachFeaturePrefs.isEnabled,
              let provider = provider as? NomicTextEmbeddingProvider else {
            selfTestSummary = "Model check unavailable while semantic memory is disabled."
            return
        }
        selfTestSummary = "Model check running…"
        do {
            let result = try await provider.runRetrievalSelfTest()
            selfTestSummary = result.passed
                ? "Passed: semantic \(result.semanticCorrect)/\(result.total), keyword \(result.keywordCorrect)/\(result.total); exact queries preserved."
                : "Needs review: semantic \(result.semanticCorrect)/\(result.total), keyword \(result.keywordCorrect)/\(result.total); exact queries \(result.exactQueriesPreserved ? "preserved" : "regressed")."
        } catch {
            selfTestSummary = "Model check failed: \(error.localizedDescription)"
        }
        await refreshStatus()
        #else
        selfTestSummary = "The Nomic runtime is currently shipped on iOS only."
        #endif
    }

    func unload() async {
        activeWork?.cancel()
        activeWork = nil
        await provider?.unload()
        await refreshStatus()
    }

    @discardableResult
    private func processPending(limit: Int) async -> Int {
        guard let provider, let store, isEnabled, CoachFeaturePrefs.isEnabled else { return 0 }
        indexingActivityCount += 1
        isIndexing = true
        defer {
            indexingActivityCount = max(0, indexingActivityCount - 1)
            isIndexing = indexingActivityCount > 0
        }
        var processed = 0
        do {
            try await provider.prepare()
            await refreshStatus()
            let pending = try await store.pending(limit: limit)
            for item in pending {
                try Task.checkCancellation()
                guard let document = liveDocuments[item.documentID],
                      document.contentHash == item.contentHash else { continue }
                let vectors = try await provider.embedDocuments([document.text])
                guard let vector = vectors.first else { continue }
                // llama.cpp cannot observe Swift cancellation while it is inside the C encode call.
                // Re-check before committing so an expired BGProcessingTask never writes after expiry.
                try Task.checkCancellation()
                try await store.storeEmbedding(documentID: item.documentID,
                                               contentHash: item.contentHash,
                                               modelID: provider.modelID,
                                               vector: vector)
                processed += 1
                await refreshProgressCounts()
            }
            try await store.setState(String(Date().timeIntervalSince1970),
                                     for: Self.lastRunStateKey)
            try await store.setState(nil, for: Self.lastErrorStateKey)
        } catch is CancellationError {
            // A committed row remains valid; the remaining rows stay pending.
        } catch {
            try? await store.setState(error.localizedDescription, for: Self.lastErrorStateKey)
        }
        await refreshStatus()
        return processed
    }

    private func runManualIndexing() async {
        isManualIndexing = true
        defer {
            isManualIndexing = false
            activeWork = nil
        }
        while !Task.isCancelled, status.pendingDocuments > 0 {
            let processed = await processPending(limit: min(32, status.pendingDocuments))
            guard processed > 0 else { break }
            await Task.yield()
        }
    }

    /// Counts are cheap indexed SQLite reads; publishing only these fields after each committed row
    /// keeps the progress bar honest without recalculating file size and state metadata thousands of
    /// times during a first build.
    private func refreshProgressCounts() async {
        guard let store, let counts = try? await store.counts() else { return }
        status = SemanticIndexStatus(
            modelID: status.modelID,
            indexedDocuments: counts.0,
            pendingDocuments: counts.1,
            byteSize: status.byteSize,
            lastRunAt: status.lastRunAt,
            lastError: status.lastError,
            isModelLoaded: true
        )
    }

    private func refreshStatus() async {
        guard let store else { return }
        let counts = (try? await store.counts()) ?? (0, 0)
        let stamp = try? await store.state(for: Self.lastRunStateKey)
        let lastRun = stamp.flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
        let error = try? await store.state(for: Self.lastErrorStateKey)
        #if os(iOS)
        let loaded = await (provider as? NomicTextEmbeddingProvider)?.isLoaded() ?? false
        #else
        let loaded = false
        #endif
        status = SemanticIndexStatus(
            modelID: provider?.modelID ?? "keyword-only",
            indexedDocuments: counts.0,
            pendingDocuments: counts.1,
            byteSize: await store.byteSize(),
            lastRunAt: lastRun,
            lastError: error ?? nil,
            isModelLoaded: loaded
        )
    }

    private func finish(_ context: String,
                        mode: CoachSemanticRetrievalMode) -> CoachSemanticRetrieval {
        lastRetrievalMode = mode
        return CoachSemanticRetrieval(context: context, mode: mode)
    }

    /// Second consent gate at the last possible point. Retrieval can suspend for model inference, so a
    /// scope may be revoked after the initial search began. Captured permissions are never sufficient
    /// for context hand-off.
    private func handoffContext(from hits: [SemanticHit],
                                requestedScopes: Set<SemanticConsentScope>) -> String {
        guard UserDefaults.standard.bool(forKey: "ai.dataConsent"),
              isEnabled,
              CoachFeaturePrefs.isEnabled else { return "" }
        let current = Self.allowedScopes(for: ToolConsent.load()).intersection(requestedScopes)
        let safeHits = hits.filter { current.contains($0.consentScope) }
        let safeDocuments = liveDocuments.filter { current.contains($0.value.consentScope) }
        return Self.context(from: safeHits, documents: safeDocuments)
    }

    static func documents(facts: [CoachMemory.MemoryFact],
                          conversations: [CoachConversation],
                          journalEntries: [JournalEntry],
                          proposals: [PlanProposal],
                          allowedScopes: Set<SemanticConsentScope>) -> [SemanticDocument] {
        var result: [SemanticDocument] = []
        if allowedScopes.contains(.memory) {
            result += memoryDocuments(facts)
            for (conversationRank, conversation) in conversations.enumerated() {
                let recentPriority = conversationRank < 5 ? 90 : 30
                if !conversation.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result += chunks(kind: .conversationTitle,
                                     sourceID: conversation.id.uuidString,
                                     text: conversation.title,
                                     updatedAt: conversation.updatedAt,
                                     scope: .memory,
                                     priority: recentPriority)
                }
                if let summary = conversation.summary,
                   !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result += chunks(kind: .conversationSummary,
                                     sourceID: conversation.id.uuidString,
                                     text: summary,
                                     updatedAt: conversation.updatedAt,
                                     scope: .memory,
                                     priority: recentPriority + 5)
                }
                for message in conversation.messages where message.role == .user {
                    result += chunks(kind: .userMessage,
                                     sourceID: message.id.uuidString,
                                     text: message.text,
                                     updatedAt: message.date,
                                     scope: .memory,
                                     priority: recentPriority)
                }
            }
        }

        for entry in journalEntries {
            let isSensitive = CoachSensitiveJournalPolicy.isSensitive(
                label: entry.question + " " + (entry.notes ?? "")
            )
            let scope: SemanticConsentScope = isSensitive ? .sensitiveLogs : .personalLogs
            guard allowedScopes.contains(scope) else { continue }
            let answer = entry.answeredYes ? "Ja" : "Nein"
            let baseID = "\(entry.day)|\(SemanticHash.fnv1a64Hex(entry.question))"
            result += chunks(kind: .journalQuestion,
                             sourceID: baseID,
                             text: "\(entry.day): \(entry.question) — \(answer)",
                             updatedAt: dayDate(entry.day),
                             scope: scope,
                             priority: isRecentDay(entry.day, days: 30) ? 80 : 20)
            if let note = entry.notes?.trimmingCharacters(in: .whitespacesAndNewlines),
               !note.isEmpty {
                result += chunks(kind: .journalNote,
                                 sourceID: baseID + "|note",
                                 text: "\(entry.day): \(entry.question) — \(answer). \(note)",
                                 updatedAt: dayDate(entry.day),
                                 scope: scope,
                                 priority: isRecentDay(entry.day, days: 30) ? 85 : 25)
            }
        }

        if allowedScopes.contains(.patterns) {
            for proposal in proposals where proposal.status.isDecided {
                let outcome: String
                switch proposal.status {
                case .declined:
                    outcome = "Recommendation declined"
                case .skipped:
                    let reason = proposal.skipReason.map { ": \($0.label)" } ?? ""
                    outcome = "Accepted recommendation not completed\(reason)"
                case .completed:
                    if let feedback = proposal.effectFeedback {
                        outcome = "Completed recommendation; effect feedback: \(feedback.label)"
                    } else {
                        outcome = "Completed recommendation; effect feedback missing"
                    }
                case .paused:
                    outcome = "Recommendation paused"
                case .accepted, .modifiedByUser, .rescheduled:
                    outcome = "Recommendation accepted; completion outcome not recorded"
                case .proposed:
                    continue
                }
                let note = proposal.feedbackNote.map { ". User note: \($0)" } ?? ""
                result += chunks(kind: .recommendationFeedback,
                                 sourceID: proposal.id.uuidString,
                                 text: "\(proposal.day): \(outcome) — \(proposal.summary())\(note)",
                                 updatedAt: proposal.decidedAt ?? proposal.createdAt,
                                 scope: .patterns,
                                 priority: proposal.effectFeedback == nil ? 45 : 70)
            }

            for report in CoachTrainingPreferences.longitudinalReports(proposals: proposals)
            where report.hasHypothesis {
                result += chunks(kind: .habitHypothesis,
                                 sourceID: "training|\(report.identifier)",
                                 text: report.text,
                                 updatedAt: proposals.compactMap(\.decidedAt).max() ?? Date.distantPast,
                                 scope: .patterns,
                                 priority: report.days == 28 ? 75 : 55)
            }
        }
        return result
    }

    private static func memoryDocuments(_ facts: [CoachMemory.MemoryFact],
                                        now: Date = Date()) -> [SemanticDocument] {
        facts
            .filter { $0.validFrom <= now && ($0.validUntil == nil || $0.validUntil! >= now) }
            .flatMap { fact in
                let status: String
                switch fact.verification {
                case .confirmed: status = "Confirmed memory"
                case .hypothesis:
                    status = "Memory hypothesis with \(fact.evidenceCount) observation(s)"
                case .pendingConfirmation:
                    status = "Unconfirmed memory; ask before relying on it"
                }
                return chunks(kind: .memoryFact,
                              sourceID: fact.id.uuidString,
                              text: "\(status): \(fact.text)",
                              updatedAt: fact.revisions.last?.changedAt ?? fact.createdAt,
                              scope: .memory,
                              priority: fact.importance == .pinned ? 120 : 100)
            }
    }

    /// Conservative word chunks plus a 24-word overlap. 192 natural-language words leave generous
    /// room for subword expansion and the task prefix; the provider remains the final authority and
    /// enforces the hard 384-token ceiling with Nomic's own tokenizer.
    private static func chunks(kind: SemanticSourceKind,
                               sourceID: String,
                               text: String,
                               updatedAt: Date,
                               scope: SemanticConsentScope,
                               priority: Int) -> [SemanticDocument] {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        let size = 192
        let overlap = 24
        var result: [SemanticDocument] = []
        var start = 0
        var chunk = 0
        while start < words.count {
            let end = min(words.count, start + size)
            result.append(SemanticDocument(sourceKind: kind,
                                           sourceID: sourceID,
                                           chunkIndex: chunk,
                                           text: words[start..<end].joined(separator: " "),
                                           updatedAt: updatedAt,
                                           consentScope: scope,
                                           priority: priority))
            guard end < words.count else { break }
            start = max(start + 1, end - overlap)
            chunk += 1
        }
        return result
    }

    private static func lexicalHits(question: String,
                                    documents: [SemanticDocument],
                                    allowedScopes: Set<SemanticConsentScope>) -> [SemanticHit] {
        let queryTokens = CoachMemory.tokens(question)
        guard !queryTokens.isEmpty else { return [] }
        return documents
            .filter { allowedScopes.contains($0.consentScope) }
            .compactMap { document -> (SemanticHit, Int)? in
                let overlap = CoachMemory.tokens(document.text).intersection(queryTokens).count
                guard overlap > 0 else { return nil }
                return (SemanticHit(documentID: document.documentID,
                                    sourceKind: document.sourceKind,
                                    sourceID: document.sourceID,
                                    chunkIndex: document.chunkIndex,
                                    score: Double(overlap),
                                    consentScope: document.consentScope), overlap)
            }
            .sorted {
                if $0.1 == $1.1 { return $0.0.documentID < $1.0.documentID }
                return $0.1 > $1.1
            }
            .map(\.0)
    }

    private static func context(from hits: [SemanticHit],
                                documents: [String: SemanticDocument]) -> String {
        var seen = Set<String>()
        let selected = hits.compactMap { hit -> SemanticDocument? in
            guard seen.insert(hit.sourceID).inserted else { return nil }
            return documents[hit.documentID]
        }.prefix(8)
        guard !selected.isEmpty else { return "" }
        var lines = ["RELEVANT LOCAL TEXT MEMORY (retrieved on device; treat as user-provided context):"]
        for document in selected {
            let label: String
            switch document.sourceKind {
            case .memoryFact: label = "Memory"
            case .conversationTitle, .conversationSummary, .userMessage: label = "Past conversation"
            case .journalQuestion, .journalNote: label = "Journal"
            case .recommendationFeedback: label = "Recommendation feedback"
            case .habitHypothesis: label = "Habit hypothesis"
            }
            lines.append("• [\(label)] \(document.text)")
        }
        return lines.joined(separator: "\n")
    }

    private static func dayDate(_ day: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: day) ?? .distantPast
    }

    private static func isRecentDay(_ day: String, days: Int) -> Bool {
        dayDate(day) >= Date().addingTimeInterval(-Double(days) * 86_400)
    }
}
