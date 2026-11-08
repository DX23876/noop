#if os(iOS)
import Foundation

/// Reports one download's progress to the main actor.
final class FoodDownloadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let report: @MainActor (Double) -> Void
    private var observation: NSKeyValueObservation?

    init(report: @escaping @MainActor (Double) -> Void) { self.report = report }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        observation = task.progress.observe(\.fractionCompleted) { [report] progress, _ in
            let value = progress.fractionCompleted
            Task { @MainActor in report(value) }
        }
    }
}
#endif
