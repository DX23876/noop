#if os(iOS)
import BackgroundTasks
import Foundation

/// The background wake for the automatic Hevy import (`HevyAutoImportRunner`). A refresh request is an
/// earliest-begin date, never a promise: iOS picks the moment, often later, and the next foreground catches up
/// on anything it skipped. Nothing is submitted while the import is off, so an install that never picks an
/// interval never asks for this wake.
@MainActor
enum HevyAutoImportBackgroundScheduler {
    static let taskIdentifier = (Bundle.main.bundleIdentifier ?? "com.noopapp.noop") + ".hevyimport"

    /// Register at launch, before the first scene connects.
    static func register(perform operation: @escaping @MainActor () async -> Void) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            let completion = TaskCompletionGuard(task: task)
            let worker = Task { @MainActor in
                await operation()
                // Armed after the run, because the next begin date depends on whether this one succeeded.
                schedule()
                guard !Task.isCancelled else { return }
                completion.finish(success: true)
            }
            task.expirationHandler = {
                worker.cancel()
                completion.finish(success: false)
            }
        }
    }

    /// Keep at most one pending request, at the next due time; none while the import is off or blocked.
    static func schedule(now: Date = Date()) {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
        guard let due = HevyAutoImportRunner.nextDue(now: now) else { return }
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = max(due, now.addingTimeInterval(15 * 60))
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Its own copy, as every other scheduler here keeps: a double `setTaskCompleted` is a programmer error and a
    /// never-completed task is grounds for killing the app, so exactly one of the two paths may finish.
    private final class TaskCompletionGuard: @unchecked Sendable {
        private let task: BGTask
        private let lock = NSLock()
        private var finished = false

        init(task: BGTask) { self.task = task }

        func finish(success: Bool) {
            lock.lock()
            defer { lock.unlock() }
            guard !finished else { return }
            finished = true
            task.setTaskCompleted(success: success)
            task.expirationHandler = nil
        }
    }
}
#endif
