import Foundation
import WhoopStore

/// A completed strength workout prepared by Coach. It remains local until the user reviews it.
struct HevyWorkoutProposal: Codable, Identifiable, Equatable {
    enum Operation: String, Codable { case create, update }
    enum Status: String, Codable { case proposed, sent, declined, failed }

    let id: UUID
    var operation: Operation
    var workout: HevyWorkout
    var previousWorkout: HevyWorkout?
    var rationale: String
    var status: Status
    let createdAt: Date
    var lastError: String?

    init(id: UUID = UUID(), operation: Operation, workout: HevyWorkout,
         previousWorkout: HevyWorkout? = nil, rationale: String,
         status: Status = .proposed, createdAt: Date = Date(), lastError: String? = nil) {
        self.id = id
        self.operation = operation
        self.workout = workout
        self.previousWorkout = previousWorkout
        self.rationale = rationale
        self.status = status
        self.createdAt = createdAt
        self.lastError = lastError
    }
}

@MainActor
final class HevyWorkoutProposalStore: ObservableObject {
    static let shared = HevyWorkoutProposalStore()
    @Published private(set) var proposals: [HevyWorkoutProposal] = [] { didSet { save() } }
    var pending: [HevyWorkoutProposal] {
        proposals.filter { $0.status == .proposed || $0.status == .failed }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private let defaults: UserDefaults
    private let storageKey: String
    private var loading = true
    private static let key = "hevy.workoutProposals.v1"

    init(defaults: UserDefaults = .standard, storageKey: String = HevyWorkoutProposalStore.key,
         loading: Bool = true) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.loading = loading
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([HevyWorkoutProposal].self, from: data) {
            proposals = decoded
        }
        self.loading = false
    }

    func propose(_ proposal: HevyWorkoutProposal) -> Bool {
        guard !proposal.workout.exercises.isEmpty else { return false }
        var value = proposal
        value.status = .proposed
        value.lastError = nil
        proposals.insert(value, at: 0)
        proposals = Array(proposals.prefix(20))
        return true
    }

    func proposal(id: UUID) -> HevyWorkoutProposal? { proposals.first { $0.id == id } }

    func decide(_ id: UUID, as status: HevyWorkoutProposal.Status, error: String? = nil) {
        guard let index = proposals.firstIndex(where: { $0.id == id }) else { return }
        proposals[index].status = status
        proposals[index].lastError = error
    }

    private func save() {
        guard !loading, let data = try? JSONEncoder().encode(proposals) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
