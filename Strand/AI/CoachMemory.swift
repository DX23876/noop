import Foundation

/// The coach's persistent memory: small facts about the user (goals, injuries, preferences) that the
/// model saves via the `remember_fact` tool, plus the user's own free-text training goal. Facts carry a
/// category and an importance so the coach can inject the RELEVANT ones per question (pinned facts always,
/// the rest ranked by keyword overlap + recency) instead of dumping all of them into every prompt.
/// UserDefaults-backed JSON (small, non-secret, on-device only). Own file: merge-clean against upstream.
@MainActor
final class CoachMemory: ObservableObject {

    /// What a fact is about — used for grouping in the UI and light prioritisation. `injury`/`goal` are
    /// the kinds a coach should never forget, so they default to being surfaced.
    enum Category: String, Codable, CaseIterable {
        case goal, injury, preference, physiology, schedule, other

        var label: String {
            switch self {
            case .goal:       return "Goal"
            case .injury:     return "Injury"
            case .preference: return "Preference"
            case .physiology: return "Physiology"
            case .schedule:   return "Schedule"
            case .other:      return "Other"
            }
        }

        var symbol: String {
            switch self {
            case .goal:       return "target"
            case .injury:     return "bandage"
            case .preference: return "heart"
            case .physiology: return "waveform.path.ecg"
            case .schedule:   return "calendar"
            case .other:      return "note.text"
            }
        }
    }

    /// How strongly a fact should be surfaced. `pinned` facts ride EVERY prompt (injuries, hard
    /// constraints); `normal` facts are injected only when relevant to the question.
    enum Importance: String, Codable { case pinned, normal }

    struct MemoryFact: Identifiable, Codable, Equatable {
        let id: UUID
        var text: String
        var category: Category
        var importance: Importance
        var createdAt: Date

        init(id: UUID = UUID(),
             text: String,
             category: Category = .other,
             importance: Importance = .normal,
             createdAt: Date = Date()) {
            self.id = id
            self.text = text
            self.category = category
            self.importance = importance
            self.createdAt = createdAt
        }

        // Back-compat: facts saved before category/importance existed decode with sensible defaults, so
        // an upgrade never drops the user's memory.
        private enum CodingKeys: String, CodingKey { case id, text, category, importance, createdAt }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(UUID.self, forKey: .id)
            text = try c.decode(String.self, forKey: .text)
            category = try c.decodeIfPresent(Category.self, forKey: .category) ?? .other
            importance = try c.decodeIfPresent(Importance.self, forKey: .importance) ?? .normal
            createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        }
    }

    /// One shared instance so the engine (writer via tool) and the settings card (viewer/editor)
    /// observe the same `@Published` state.
    static let shared = CoachMemory()

    /// Saved facts, newest first. Capped so the store can't grow without bound.
    @Published private(set) var facts: [MemoryFact] { didSet { saveFacts() } }

    private let d: UserDefaults
    private static let factsKey = "ai.memory.facts"
    /// Hard cap on stored facts — old ones fall off the end when the model over-remembers.
    static let maxFacts = 40

    init(defaults: UserDefaults = .standard) {
        self.d = defaults
        self.facts = (try? JSONDecoder().decode([MemoryFact].self,
                                                from: defaults.data(forKey: Self.factsKey) ?? Data())) ?? []
    }

    // MARK: - Mutations

    /// Add a fact (newest first), enforcing the cap. Near-duplicates (same normalised text, or one text
    /// fully contained in the other) UPDATE the existing fact in place instead of stacking a rephrasing,
    /// so the 40-slot budget isn't wasted. Returns false only when the text is empty.
    ///
    /// Only matched against facts in the SAME category — dedup is category-scoped (see `isNearDuplicate`),
    /// so an "injury" restating a knee problem never collapses onto an unrelated "preference".
    @discardableResult
    func add(_ text: String, category: Category = .other, importance: Importance = .normal) -> Bool {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return false }
        let key = Self.normalize(clean)
        if let idx = facts.firstIndex(where: {
            $0.category == category && Self.isNearDuplicate(Self.normalize($0.text), key, category: category)
        }) {
            // Supersede the near-duplicate: keep its id, refresh text/recency. Importance/category are
            // never DOWNGRADED by a restatement — a rephrasing of a pinned injury must not quietly demote
            // it out of `pinnedBlock` just because the caller passed a looser importance this time.
            facts[idx].text = clean
            if importance == .pinned { facts[idx].importance = .pinned }
            facts[idx].createdAt = Date()
            facts.sort { $0.createdAt > $1.createdAt }
            return true
        }
        let fact = MemoryFact(text: clean, category: category, importance: importance)
        // Evict the OLDEST NON-pinned fact first when at the cap, so a pinned fact (injuries, hard
        // constraints) never falls off just because it happens to be old.
        var updated = [fact] + facts
        if updated.count > Self.maxFacts {
            if let dropIdx = updated.lastIndex(where: { $0.importance != .pinned }) {
                updated.remove(at: dropIdx)
            } else {
                updated.removeLast()   // every fact is pinned — nothing safe to keep, drop the oldest anyway
            }
        }
        facts = updated
        return true
    }

    /// Edit a fact's text in place (a model correction, or the user editing in settings).
    @discardableResult
    func update(_ id: UUID, text: String) -> Bool {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let idx = facts.firstIndex(where: { $0.id == id }) else { return false }
        facts[idx].text = clean
        return true
    }

    /// Find a fact whose text near-matches `query` (for the model's forget/update-by-text tools). The
    /// tools don't supply a category to match against, so this uses the STRICTEST thresholds (`.injury`'s)
    /// regardless of the candidate's own category — handing `forget_fact`/`update_fact` the wrong fact is
    /// worse than it occasionally not finding the right one.
    func firstMatch(_ query: String) -> MemoryFact? {
        let key = Self.normalize(query)
        guard !key.isEmpty else { return nil }
        return facts.first(where: { Self.isNearDuplicate(Self.normalize($0.text), key, category: .injury) })
    }

    func remove(_ id: UUID) {
        facts = facts.filter { $0.id != id }
    }

    func clearAll() {
        facts = []
    }

    // MARK: - Retrieval

    /// Pinned facts — the block that rides EVERY prompt because it's always relevant. The training goal
    /// used to live here as a bare sentence; it now has its own structured model (`CoachGoal`) and is
    /// injected by `AICoachEngine.goalBlock` with its dates, remaining change and pace verdict.
    var pinnedBlock: String {
        var lines: [String] = []
        let pinned = facts.filter { $0.importance == .pinned }
        if !pinned.isEmpty {
            lines.append("ALWAYS-RELEVANT FACTS ABOUT THE USER (rely on these every time):")
            for f in pinned { lines.append("• \(f.text)") }
        }
        return lines.joined(separator: "\n")
    }

    /// The `limit` facts most relevant to `query`: pinned first, then normal facts ranked by keyword
    /// overlap with the question, decayed by age. Injected into the question's context so the coach gets
    /// the pertinent memory without every prompt carrying all 40 facts.
    func relevantFacts(for query: String, limit: Int, now: Date = Date()) -> [MemoryFact] {
        let pinned = facts.filter { $0.importance == .pinned }
        let rest = facts.filter { $0.importance != .pinned }
        let qTokens = Self.tokens(query)
        let ranked = rest
            .map { fact -> (MemoryFact, Double) in (fact, Self.relevanceScore(fact, qTokens, now: now)) }
            .sorted { $0.1 > $1.1 }
            .map { $0.0 }
        // Always take pinned; fill the remaining budget with the highest-ranked normal facts.
        let normalBudget = max(0, limit - pinned.count)
        return pinned + Array(ranked.prefix(normalBudget))
    }

    /// Keyword overlap decayed by age, so an old fact's relevance actually fades instead of only ever
    /// breaking a tie — see `relevanceScore` for the exact formula. A fact with ZERO overlap still scores
    /// zero regardless of age — decay only discounts an already-relevant fact, it never manufactures
    /// relevance for an unrelated one. A real half-life, not a hard cutoff, so nothing vanishes abruptly;
    /// a fact that's still clearly relevant (high overlap) stays competitive well past 30 days.
    static let recencyHalfLifeDays: Double = 30

    /// Not `private` so `CoachMemoryRankingTests` can pin the decay formula directly, without needing to
    /// seed a whole `CoachMemory`/`UserDefaults` fixture just to reach it through `relevantFacts`.
    static func relevanceScore(_ fact: MemoryFact, _ qTokens: Set<String>, now: Date) -> Double {
        let overlap = Double(Self.overlap(Self.tokens(fact.text), qTokens))
        guard overlap > 0 else { return 0 }
        let ageDays = max(0, now.timeIntervalSince(fact.createdAt) / 86_400)
        // ln(2) makes this an actual half-life: the score is exactly half at ageDays == recencyHalfLifeDays,
        // not merely "smaller" — plain exp(-ageDays/halfLife) decays to ~0.37 there, not 0.5.
        return overlap * exp(-log(2) * ageDays / recencyHalfLifeDays)
    }

    /// The relevant-facts block for a specific question (used by the context builder). Empty when there's
    /// nothing beyond what `pinnedBlock` already carries.
    func relevantBlock(for query: String, limit: Int) -> String {
        let picked = relevantFacts(for: query, limit: limit).filter { $0.importance != .pinned }
        guard !picked.isEmpty else { return "" }
        var lines = ["POSSIBLY-RELEVANT FACTS ABOUT THE USER (from memory):"]
        for f in picked { lines.append("• \(f.text)") }
        return lines.joined(separator: "\n")
    }

    // MARK: - Text helpers

    /// Very small stopword set so keyword overlap keys on the meaningful words.
    private static let stopwords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "to", "of", "in", "on", "for", "with", "my", "me", "i",
        "is", "are", "was", "were", "be", "do", "does", "did", "how", "what", "why", "when", "should",
        "about", "your", "you", "this", "that", "it", "at", "as", "so", "if", "can", "will", "im"
    ]

    /// Lowercased, punctuation-stripped word tokens ≥ 3 chars, stopwords removed.
    static func tokens(_ s: String) -> Set<String> {
        let lowered = s.lowercased()
        let parts = lowered.split { !$0.isLetter && !$0.isNumber }
        return Set(parts.map(String.init).filter { $0.count >= 3 && !stopwords.contains($0) })
    }

    private static func overlap(_ a: Set<String>, _ b: Set<String>) -> Int { a.intersection(b).count }

    /// A normalised form for duplicate detection: lowercased, only letters/numbers, single-spaced.
    static func normalize(_ s: String) -> String {
        let lowered = s.lowercased()
        let kept = lowered.map { ($0.isLetter || $0.isNumber || $0 == " ") ? $0 : " " }
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    /// How much of the smaller fact's meaningful vocabulary must appear in the other before the two are
    /// treated as the same fact reworded, for callers with no category context (kept as the loose,
    /// catch-all default so existing direct callers of `hasDuplicateTokenOverlap(_:_:)` are unaffected).
    static let duplicateTokenOverlap: Double = 0.8
    /// Below this many meaningful tokens, overlap is meaningless ("knee pain" vs "knee sore" would
    /// collapse), so short facts fall back to the string tests alone.
    static let minTokensForOverlapMatch = 3

    /// Per-category dedup strictness: (token-overlap ratio, containment length-ratio, min meaningful
    /// tokens for the overlap test to apply). `.injury`/`.goal` need near-medical precision — "ACL tear"
    /// and "meniscus tear" share a lot of vocabulary but are different facts, so a wrong collapse there is
    /// the costliest kind of data loss. `.physiology` sits in between. Casual restatements (`.preference`,
    /// `.schedule`, `.other`) can collapse more readily — losing a rephrasing there costs nothing.
    static func thresholds(for category: Category) -> (overlap: Double, containment: Double, minTokens: Int) {
        switch category {
        case .injury, .goal:
            return (0.85, 0.80, 5)
        case .physiology:
            return (0.75, 0.70, 4)
        case .preference, .schedule, .other:
            return (0.65, 0.65, 3)
        }
    }

    /// Two normalised strings are near-duplicates when equal, when one contains the other and they're
    /// close in length (a rephrasing/extension of the same fact), or when their meaningful words almost
    /// entirely overlap — at the strictness `category` calls for (see `thresholds(for:)`).
    ///
    /// That last test is why re-summarising a chat no longer stacks memory: a cheap model asked twice
    /// about the same conversation says the same thing in different words ("Runs three times a week" vs
    /// "The user runs 3x per week"), which the string tests miss entirely and which used to land as a
    /// second fact against the 40-slot cap.
    static func isNearDuplicate(_ a: String, _ b: String, category: Category) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        let (shorter, longer) = a.count <= b.count ? (a, b) : (b, a)
        let t = thresholds(for: category)
        // Only treat containment as duplicate when the shorter is a substantial part of the longer, so
        // "knee" doesn't collapse an unrelated longer fact that merely contains the word.
        if longer.contains(shorter), Double(shorter.count) / Double(longer.count) >= t.containment {
            return true
        }
        return hasDuplicateTokenOverlap(a, b, minTokens: t.minTokens, overlapThreshold: t.overlap)
    }

    /// Back-compat overload for callers with no category context — uses the loosest, catch-all (`.other`)
    /// thresholds.
    static func isNearDuplicate(_ a: String, _ b: String) -> Bool {
        isNearDuplicate(a, b, category: .other)
    }

    /// The token-overlap arm of `isNearDuplicate`: near-total shared vocabulary, measured against the
    /// SMALLER set so a fact that merely adds detail to a known one still collapses onto it.
    static func hasDuplicateTokenOverlap(_ a: String, _ b: String,
                                         minTokens: Int = minTokensForOverlapMatch,
                                         overlapThreshold: Double = duplicateTokenOverlap) -> Bool {
        let ta = tokens(a), tb = tokens(b)
        guard ta.count >= minTokens, tb.count >= minTokens else { return false }
        let shared = ta.intersection(tb).count
        let smaller = min(ta.count, tb.count)
        return Double(shared) / Double(smaller) >= overlapThreshold
    }

    private func saveFacts() {
        if let data = try? JSONEncoder().encode(facts) { d.set(data, forKey: Self.factsKey) }
    }
}
