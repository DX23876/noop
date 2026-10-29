import Foundation
import WhoopStore

/// Immutable workout snapshot used by reconciliation UI and completion evidence. `WorkoutRow` has no
/// stable id, so the key intentionally excludes source: the repository may choose a richer cross-source
/// twin after a later import, but it is still the same start/end/sport activity.
struct PlanWorkoutReference: Codable, Equatable, Identifiable {
    let workoutKey: String
    let startTs: Int
    let endTs: Int
    let sport: String
    let source: String
    let durationS: Double?
    let strain: Double?
    let distanceM: Double?

    var id: String { workoutKey }

    init(_ row: WorkoutRow) {
        workoutKey = Self.key(startTs: row.startTs, endTs: row.endTs, sport: row.sport)
        startTs = row.startTs
        endTs = row.endTs
        sport = row.sport
        source = row.source
        durationS = row.durationS
        strain = row.strain
        distanceM = row.distanceM
    }

    static func key(startTs: Int, endTs: Int, sport: String) -> String {
        "\(startTs)|\(endTs)|\(normalizedLabel(sport))"
    }

    static func normalizedLabel(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

}
