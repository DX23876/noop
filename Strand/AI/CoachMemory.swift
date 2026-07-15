import Foundation

/// The coach's persistent memory: small facts about the user (goals, injuries, preferences) that the
/// model saves via the `remember_fact` tool, plus the user's own free-text training goal. Injected into
/// the system prompt so the coach knows the user across sessions — the heart of real personalisation.
/// UserDefaults-backed JSON (small, non-secret, on-device only). Own file: merge-clean against upstream.
@MainActor
final class CoachMemory: ObservableObject {

    struct MemoryFact: Identifiable, Codable, Equatable {
        let id: UUID
        let text: String
        let createdAt: Date

        init(id: UUID = UUID(), text: String, createdAt: Date = Date()) {
            self.id = id
            self.text = text
            self.createdAt = createdAt
        }
    }

    /// One shared instance so the engine (writer via tool) and the settings card (viewer/editor)
    /// observe the same `@Published` state.
    static let shared = CoachMemory()

    /// Saved facts, newest first. Capped so the prompt block can't grow without bound.
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

    /// Add a fact (newest first), skipping exact duplicates and enforcing the cap. Returns false when
    /// the text was empty/duplicate so the tool can report honestly.
    @discardableResult
    func add(_ text: String) -> Bool {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !facts.contains(where: { $0.text == clean }) else { return false }
        facts = Array(([MemoryFact(text: clean)] + facts).prefix(Self.maxFacts))
        return true
    }

    func remove(_ id: UUID) {
        facts = facts.filter { $0.id != id }
    }

    func clearAll() {
        facts = []
    }

    /// The block appended to the system prompt when anything is stored: the user's goal + saved facts.
    /// Empty string when there's nothing, so the prompt stays untouched for fresh users.
    var promptBlock: String {
        var lines: [String] = []
        let goal = trainingGoal.trimmingCharacters(in: .whitespacesAndNewlines)
        if !goal.isEmpty { lines.append("The user's stated training goal: \(goal)") }
        if !facts.isEmpty {
            lines.append("KNOWN FACTS ABOUT THE USER (your persistent memory — rely on these):")
            for f in facts { lines.append("• \(f.text)") }
        }
        return lines.joined(separator: "\n")
    }

    private func saveFacts() {
        if let data = try? JSONEncoder().encode(facts) { d.set(data, forKey: Self.factsKey) }
    }
}
