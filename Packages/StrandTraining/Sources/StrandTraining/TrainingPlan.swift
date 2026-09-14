import Foundation

public enum TrainingWeekday: Int, Codable, CaseIterable, Sendable {
    case monday = 1, tuesday, wednesday, thursday, friday, saturday, sunday
}

public enum TrainingWeekStart: String, Codable, CaseIterable, Sendable {
    case monday
    case sunday
}

public struct TrainingDayOverride: Identifiable, Codable, Equatable, Sendable {
    public var id: String { day }
    public let day: String
    public var routineIds: [UUID]
    public var isRest: Bool

    public init(day: String, routineIds: [UUID] = [], isRest: Bool = false) {
        self.day = day
        self.routineIds = routineIds
        self.isRest = isRest
    }
}

public struct TrainingPlan: Codable, Equatable, Sendable {
    public var routines: [TrainingRoutine]
    public var schedule: [TrainingWeekday: [UUID]]
    public var overrides: [TrainingDayOverride]
    public var weekStartsOn: TrainingWeekStart

    public init(routines: [TrainingRoutine] = [], schedule: [TrainingWeekday: [UUID]] = [:],
                overrides: [TrainingDayOverride] = [], weekStartsOn: TrainingWeekStart = .monday) {
        self.routines = routines
        self.schedule = schedule
        self.overrides = overrides
        self.weekStartsOn = weekStartsOn
    }

    public func effectiveRoutineIds(day: String, weekday: TrainingWeekday) -> [UUID] {
        if let override = overrides.last(where: { $0.day == day }) {
            return override.isRest ? [] : valid(override.routineIds)
        }
        return valid(schedule[weekday] ?? [])
    }

    public func routines(day: String, weekday: TrainingWeekday) -> [TrainingRoutine] {
        let byId = Dictionary(uniqueKeysWithValues: routines.map { ($0.id, $0) })
        return effectiveRoutineIds(day: day, weekday: weekday).compactMap { byId[$0] }
    }

    private func valid(_ ids: [UUID]) -> [UUID] {
        let known = Set(routines.map(\.id))
        var seen = Set<UUID>()
        return ids.filter { known.contains($0) && seen.insert($0).inserted }
    }
}
