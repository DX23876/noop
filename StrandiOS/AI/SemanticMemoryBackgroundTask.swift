#if os(iOS)
import BackgroundTasks
import Foundation

/// Best-effort, one-shot iOS maintenance. It is an optimisation only: opening Coach always reconciles
/// and indexes the relevant backlog even if iOS never grants background execution.
enum SemanticMemoryBackgroundTask {
    static var identifier: String {
        (Bundle.main.bundleIdentifier ?? "com.noopapp.noop") + ".semanticmemory"
    }

    @MainActor private static weak var coach: AICoachEngine?

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(processingTask)
        }
    }

    @MainActor
    static func attach(coach: AICoachEngine) {
        self.coach = coach
    }

    static func schedule() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        let request = BGProcessingTaskRequest(identifier: identifier)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = true
        request.earliestBeginDate = nextNightlyWindow()
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func handle(_ task: BGProcessingTask) {
        let work = Task { @MainActor in
            guard let coach, CoachFeaturePrefs.isEnabled,
                  CoachSemanticMemory.shared.isEnabled else {
                task.setTaskCompleted(success: true)
                schedule()
                return
            }
            await coach.performSemanticMemoryMaintenance()
            task.setTaskCompleted(success: !Task.isCancelled)
            schedule()
        }
        task.expirationHandler = {
            work.cancel()
            Task { @MainActor in
                await coach?.unloadSemanticMemory()
            }
        }
    }

    /// A nightly preference, never a promise: BGTaskScheduler may deliver substantially later.
    private static func nextNightlyWindow(now: Date = Date()) -> Date {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        let tonight = calendar.date(byAdding: .hour, value: 2, to: startOfToday)
            ?? now.addingTimeInterval(3_600)
        return tonight > now ? tonight : (calendar.date(byAdding: .day, value: 1, to: tonight)
            ?? now.addingTimeInterval(86_400))
    }
}
#endif
