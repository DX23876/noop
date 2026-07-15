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

    /// The user's free-text training goal ("Half marathon in October"). Persisted separately from the
    /// facts so clearing the memory never wipes the goal the user typed themselves.
    @Published var trainingGoal: String { didSet { d.set(trainingGoal, forKey: Self.goalKey) } }

    private let d: UserDefaults
    private static let factsKey = "ai.memory.facts"
    private static let goalKey = "ai.trainingGoal"
    /// Hard cap on stored facts — old ones fall off the end when the model over-remembers.
    static let maxFacts = 40

    init(defaults: UserDefaults = .standard) {
        self.d = defaults
        self.facts = (try? JSONDecoder().decode([MemoryFact].self,
                                                from: defaults.data(forKey: Self.factsKey) ?? Data())) ?? []
        self.trainingGoal = defaults.string(forKey: Self.goalKey) ?? ""
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

    /// Pinned facts + the goal — the block that rides EVERY prompt because it's always relevant.
    var pinnedBlock: String {
        var lines: [String] = []
        let goal = trainingGoal.trimmingCharacters(in: .whitespacesAndNewlines)
        if !goal.isEmpty { lines.append("The user's stated training goal: \(goal)") }
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
        return pinned + ranked.prefix(normalBudget)
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

    /// Two normalised strings are near-duplicates when equal, or one contains the other and they're
    /// close in length (a rephrasing/extension of the same fact), not two unrelated facts.
    static func isNearDuplicate(_ a: String, _ b: String) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        let (shorter, longer) = a.count <= b.count ? (a, b) : (b, a)
        guard longer.contains(shorter) else { return false }
        // Only treat containment as duplicate when the shorter is a substantial part of the longer, so
        // "knee" doesn't collapse an unrelated longer fact that merely contains the word.
        return Double(shorter.count) / Double(longer.count) >= 0.6
    }

    private func saveFacts() {
        if let data = try? JSONEncoder().encode(facts) { d.set(data, forKey: Self.factsKey) }
    }
}
