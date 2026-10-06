import Foundation
import StrandAnalytics

/// User-authored templates are local data; each session receives its own copied plan.
enum WorkoutGuidancePreferences {
    struct Template: Codable, Identifiable {
        let id: UUID
        let name: String
        let phases: [WorkoutGuidance.Phase]
    }
    static let enabledKey = "workout.guidance.enabled"
    static let planKey = "workout.guidance.plan"
    static let templatesKey = "workout.guidance.templates"
    static let pacerKey = "workout.pacer.enabled"
    static let pacerMetersKey = "workout.pacer.meters"
    static let pacerSecondsKey = "workout.pacer.seconds"

    static func pacer(gpsEnabled: Bool, defaults: UserDefaults = .standard) -> WorkoutPacer? {
        guard gpsEnabled, defaults.bool(forKey: pacerKey) else { return nil }
        let value = WorkoutPacer(meters: defaults.object(forKey: pacerMetersKey) as? Double ?? 5000,
                                 seconds: defaults.object(forKey: pacerSecondsKey) as? Double ?? 1800)
        return value.isValid ? value : nil
    }

    static func plan(gpsEnabled: Bool, defaults: UserDefaults = .standard) -> WorkoutGuidance? {
        guard defaults.bool(forKey: enabledKey),
              let plan = storedPlan(defaults: defaults),
              !plan.requiresGPS || gpsEnabled else { return nil }
        return WorkoutGuidance(phases: plan.phases)
    }

    /// The editor must retain a saved plan even when guidance or GPS is currently switched off.
    static func storedPlan(defaults: UserDefaults = .standard) -> WorkoutGuidance? {
        guard let data = defaults.string(forKey: planKey)?.data(using: .utf8),
              let plan = try? JSONDecoder().decode(WorkoutGuidance.self, from: data), plan.isValid else { return nil }
        return WorkoutGuidance(phases: plan.phases)
    }

    static func save(_ plan: WorkoutGuidance, defaults: UserDefaults = .standard) {
        guard plan.isValid, let data = try? JSONEncoder().encode(WorkoutGuidance(phases: plan.phases)) else { return }
        defaults.set(String(decoding: data, as: UTF8.self), forKey: planKey)
    }

    static func templates(defaults: UserDefaults = .standard) -> [Template] {
        guard let data = defaults.string(forKey: templatesKey)?.data(using: .utf8),
              let values = try? JSONDecoder().decode([Template].self, from: data) else { return [] }
        var seen: Set<UUID> = []
        return values.filter { WorkoutGuidance(phases: $0.phases).isValid && !$0.name.isEmpty && seen.insert($0.id).inserted }
    }

    static func saveTemplate(name: String, plan: WorkoutGuidance, defaults: UserDefaults = .standard) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, plan.isValid else { return }
        var values = templates(defaults: defaults)
        values.append(Template(id: UUID(), name: String(name.prefix(80)), phases: plan.phases))
        guard let data = try? JSONEncoder().encode(values) else { return }
        defaults.set(String(decoding: data, as: UTF8.self), forKey: templatesKey)
    }

    static func deleteTemplates(ids: Set<UUID>, defaults: UserDefaults = .standard) {
        let remaining = templates(defaults: defaults).filter { !ids.contains($0.id) }
        guard let data = try? JSONEncoder().encode(remaining) else { return }
        defaults.set(String(decoding: data, as: UTF8.self), forKey: templatesKey)
    }
}
