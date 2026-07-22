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
    @discardableResult
    func add(_ text: String, category: Category = .other, importance: Importance = .normal) -> Bool {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return false }
        let key = Self.normalize(clean)
        if let idx = facts.firstIndex(where: { Self.isNearDuplicate(Self.normalize($0.text), key) }) {
            // Supersede the near-duplicate: keep its id, refresh text/category/importance/recency.
            facts[idx].text = clean
            facts[idx].category = category
            facts[idx].importance = importance
            facts[idx].createdAt = Date()
            facts.sort { $0.createdAt > $1.createdAt }
            return true
        }
        let fact = MemoryFact(text: clean, category: category, importance: importance)
        facts = Array(([fact] + facts).prefix(Self.maxFacts))
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

    /// Find a fact whose text near-matches `query` (for the model's forget/update-by-text tools).
    func firstMatch(_ query: String) -> MemoryFact? {
        let key = Self.normalize(query)
        guard !key.isEmpty else { return nil }
        return facts.first(where: { Self.isNearDuplicate(Self.normalize($0.text), key) })
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
    /// overlap with the question, then recency. Injected into the question's context so the coach gets
    /// the pertinent memory without every prompt carrying all 40 facts.
    func relevantFacts(for query: String, limit: Int) -> [MemoryFact] {
        let pinned = facts.filter { $0.importance == .pinned }
        let rest = facts.filter { $0.importance != .pinned }
        let qTokens = Self.tokens(query)
        let ranked = rest
            .map { fact -> (MemoryFact, Int) in (fact, Self.overlap(Self.tokens(fact.text), qTokens)) }
            .sorted { a, b in
                if a.1 != b.1 { return a.1 > b.1 }              // more keyword overlap first
                return a.0.createdAt > b.0.createdAt            // then more recent
            }
            .map { $0.0 }
        // Always take pinned; fill the remaining budget with the highest-ranked normal facts.
        let normalBudget = max(0, limit - pinned.count)
        return pinned + Array(ranked.prefix(normalBudget))
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
    /// treated as the same fact reworded. High on purpose: memory losing a genuinely new fact is worse
    /// than carrying one rephrasing, so this only fires on near-total overlap.
    static let duplicateTokenOverlap: Double = 0.8
    /// Below this many meaningful tokens, overlap is meaningless ("knee pain" vs "knee sore" would
    /// collapse), so short facts fall back to the string tests alone.
    static let minTokensForOverlapMatch = 3

    /// Two normalised strings are near-duplicates when equal, when one contains the other and they're
    /// close in length (a rephrasing/extension of the same fact), or when their meaningful words almost
    /// entirely overlap.
    ///
    /// That last test is why re-summarising a chat no longer stacks memory: a cheap model asked twice
    /// about the same conversation says the same thing in different words ("Runs three times a week" vs
    /// "The user runs 3x per week"), which the string tests miss entirely and which used to land as a
    /// second fact against the 40-slot cap.
    static func isNearDuplicate(_ a: String, _ b: String) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        let (shorter, longer) = a.count <= b.count ? (a, b) : (b, a)
        // Only treat containment as duplicate when the shorter is a substantial part of the longer, so
        // "knee" doesn't collapse an unrelated longer fact that merely contains the word.
        if longer.contains(shorter), Double(shorter.count) / Double(longer.count) >= 0.6 { return true }
        return hasDuplicateTokenOverlap(a, b)
    }

    /// The token-overlap arm of `isNearDuplicate`: near-total shared vocabulary, measured against the
    /// SMALLER set so a fact that merely adds detail to a known one still collapses onto it.
    static func hasDuplicateTokenOverlap(_ a: String, _ b: String) -> Bool {
        let ta = tokens(a), tb = tokens(b)
        guard ta.count >= minTokensForOverlapMatch, tb.count >= minTokensForOverlapMatch else { return false }
        let shared = ta.intersection(tb).count
        let smaller = min(ta.count, tb.count)
        return Double(shared) / Double(smaller) >= duplicateTokenOverlap
    }

    private func saveFacts() {
        if let data = try? JSONEncoder().encode(facts) { d.set(data, forKey: Self.factsKey) }
    }
}
