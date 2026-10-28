import Foundation

/// The transfer half of an optional media pack: a background URLSession download with progress,
/// cancellation and resume.
///
/// Background rather than an in-process request because the pack is large: iOS keeps the transfer
/// running when the app is suspended and hands the finished file back on relaunch. A cancelled or
/// failed transfer keeps its resume data, so continuing costs only the remaining bytes.
///
/// The handlers are attached once and stay attached. A transfer finished while the app was not running
/// is delivered as soon as the session is recreated on the next launch, before anybody taps anything;
/// one-shot handlers set by `start` dropped exactly that delivery, so the finished archive stayed in the
/// system's download folder and the pack never installed.
final class ExerciseMediaDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    typealias ProgressHandler = @Sendable (Double) -> Void
    typealias CompletionHandler = @Sendable (Result<URL, Error>) -> Void

    static let backgroundIdentifier = "app.noop.exercise-media"
    /// The one background downloader of the process. Two sessions with one background identifier are
    /// undefined behaviour, and the second one is the one that never hears about the transfer.
    static let background = ExerciseMediaDownloader(identifier: backgroundIdentifier, background: true)

    /// Set by the iOS app delegate when the system relaunches the app for a finished transfer.
    nonisolated(unsafe) static var backgroundCompletionHandler: (@Sendable () -> Void)?

    private let lock = NSLock()
    private var session: URLSession!
    private var task: URLSessionDownloadTask?
    private var onProgress: ProgressHandler?
    private var onCompletion: CompletionHandler?
    private var storedResumeData: Data?
    /// Transfers cancelled as duplicates or by `discard`. Their cancellation arrives later and must not
    /// read as the end of the transfer that replaced them.
    private var ignoredTaskIds: Set<Int> = []
    /// The size to show progress against when the server sends no length. GitHub's generated archives
    /// are streamed without one, which left the bar at zero for the whole download.
    private var fallbackExpectedBytes: Int64 = 0

    var canResume: Bool {
        lock.lock(); defer { lock.unlock() }
        return storedResumeData != nil
    }

    init(identifier: String = backgroundIdentifier, background: Bool = true) {
        super.init()
        let configuration: URLSessionConfiguration = background
            ? .background(withIdentifier: identifier)
            : .default
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    func attach(expectedBytes: Int64, onProgress: @escaping ProgressHandler,
                onCompletion: @escaping CompletionHandler) {
        lock.lock()
        fallbackExpectedBytes = expectedBytes
        self.onProgress = onProgress
        self.onCompletion = onCompletion
        lock.unlock()
    }

    /// Reports whether a transfer from an earlier launch is still running in the session.
    func pendingTransfer(_ completion: @escaping @Sendable (Bool) -> Void) {
        session.getAllTasks { [weak self] tasks in
            let running = tasks.compactMap { $0 as? URLSessionDownloadTask }.first { $0.state == .running }
            if let running, let self {
                self.lock.lock(); self.task = running; self.lock.unlock()
            }
            completion(running != nil)
        }
    }

    /// Starts the pack, or continues it from resume data. A transfer already running in the session is
    /// adopted instead of starting a second copy of the same archive next to it.
    func start(url: URL) {
        session.getAllTasks { [weak self] tasks in
            guard let self else { return }
            self.lock.lock(); let ignored = self.ignoredTaskIds; self.lock.unlock()
            let downloads = tasks.compactMap { $0 as? URLSessionDownloadTask }.filter { !ignored.contains($0.taskIdentifier) }
            if let running = downloads.first(where: { $0.state == .running || $0.state == .suspended }) {
                let duplicates = downloads.filter { $0 !== running }
                self.lock.lock()
                self.ignoredTaskIds.formUnion(duplicates.map(\.taskIdentifier))
                self.task = running
                self.storedResumeData = nil
                self.lock.unlock()
                duplicates.forEach { $0.cancel() }
                running.resume()
                return
            }
            self.lock.lock()
            let resumeData = self.storedResumeData
            self.storedResumeData = nil
            let task = resumeData.map { self.session.downloadTask(withResumeData: $0) }
                ?? self.session.downloadTask(with: url)
            self.task = task
            self.lock.unlock()
            task.resume()
        }
    }

    /// Keeps the resume data so the wearer can continue instead of starting the pack again.
    func cancel() {
        lock.lock()
        let task = self.task
        self.task = nil
        lock.unlock()
        task?.cancel { [weak self] data in
            guard let self, let data else { return }
            self.lock.lock()
            self.storedResumeData = data
            self.lock.unlock()
        }
    }

    /// Cancels every transfer in the session and forgets the resume data, so the next start fetches a
    /// fresh archive.
    func discard() {
        lock.lock()
        if let task { ignoredTaskIds.insert(task.taskIdentifier) }
        task = nil
        storedResumeData = nil
        lock.unlock()
        session.getAllTasks { [weak self] tasks in
            guard let self else { return }
            self.lock.lock(); self.ignoredTaskIds.formUnion(tasks.map(\.taskIdentifier)); self.lock.unlock()
            tasks.forEach { $0.cancel() }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite totalBytesExpectedToWrite: Int64) {
        lock.lock(); let handler = onProgress; let fallback = fallbackExpectedBytes; lock.unlock()
        let value: Double
        if totalBytesExpectedToWrite > 0 {
            value = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        } else if fallback > 0 {
            // Only an estimate, so it stops short of full until the archive has really arrived.
            value = min(0.99, Double(totalBytesWritten) / Double(fallback))
        } else {
            return
        }
        handler?(min(1, max(0, value)))
    }

    /// The delegate must move the file before returning: the system deletes it as soon as this call
    /// ends, so the staging copy happens here rather than on the main actor.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let response = downloadTask.response as? HTTPURLResponse
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("exercise-media-\(UUID().uuidString).zip")
        do {
            guard response.map({ (200..<300).contains($0.statusCode) }) ?? true else {
                throw ExerciseMediaTransferError.unsupportedResponse
            }
            try FileManager.default.moveItem(at: location, to: destination)
            complete(.success(destination), task: downloadTask)
        } catch {
            complete(.failure(error), task: downloadTask)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let nsError = error as NSError
        lock.lock()
        let ignored = ignoredTaskIds.remove(task.taskIdentifier) != nil
        let isCurrent = !ignored && (self.task == nil || self.task === task)
        if isCurrent, let data = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            storedResumeData = data
        }
        lock.unlock()
        // A duplicate that `start` or `discard` cancelled is not news for the wearer.
        guard isCurrent else { return }
        if nsError.code == NSURLErrorCancelled {
            complete(.failure(ExerciseMediaTransferError.cancelled), task: task)
            return
        }
        complete(.failure(error), task: task)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let handler = Self.backgroundCompletionHandler
        Self.backgroundCompletionHandler = nil
        handler?()
    }

    private func complete(_ result: Result<URL, Error>, task finished: URLSessionTask) {
        lock.lock()
        let ignored = ignoredTaskIds.remove(finished.taskIdentifier) != nil
        let handler = ignored ? nil : onCompletion
        if task === finished { task = nil }
        lock.unlock()
        if ignored, case .success(let file) = result { try? FileManager.default.removeItem(at: file) }
        handler?(result)
    }
}

enum ExerciseMediaTransferError: LocalizedError {
    case unsupportedResponse
    case cancelled

    var errorDescription: String? {
        switch self {
        case .unsupportedResponse: return String(localized: "The media provider returned an unsupported response.")
        case .cancelled: return String(localized: "The download was cancelled.")
        }
    }
}
