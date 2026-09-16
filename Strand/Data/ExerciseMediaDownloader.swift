import Foundation

/// The transfer half of an optional media pack: a background URLSession download with progress,
/// cancellation and resume.
///
/// Background rather than an in-process request because the pack is large: iOS keeps the transfer
/// running when the app is suspended and hands the finished file back on relaunch. A cancelled or
/// failed transfer keeps its resume data, so continuing costs only the remaining bytes.
final class ExerciseMediaDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    typealias ProgressHandler = @Sendable (Double) -> Void
    typealias CompletionHandler = @Sendable (Result<URL, Error>) -> Void

    /// Set by the iOS app delegate when the system relaunches the app for a finished transfer.
    nonisolated(unsafe) static var backgroundCompletionHandler: (@Sendable () -> Void)?

    private let lock = NSLock()
    private var session: URLSession!
    private var task: URLSessionDownloadTask?
    private var onProgress: ProgressHandler?
    private var onCompletion: CompletionHandler?
    private var storedResumeData: Data?

    var canResume: Bool {
        lock.lock(); defer { lock.unlock() }
        return storedResumeData != nil
    }

    init(identifier: String = "app.noop.exercise-media", background: Bool = true) {
        super.init()
        let configuration: URLSessionConfiguration = background
            ? .background(withIdentifier: identifier)
            : .default
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    func start(url: URL, onProgress: @escaping ProgressHandler, onCompletion: @escaping CompletionHandler) {
        lock.lock()
        self.onProgress = onProgress
        self.onCompletion = onCompletion
        let resumeData = storedResumeData
        storedResumeData = nil
        let task = resumeData.map { session.downloadTask(withResumeData: $0) }
            ?? session.downloadTask(with: url)
        self.task = task
        lock.unlock()
        task.resume()
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

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let value = min(1, max(0, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
        lock.lock(); let handler = onProgress; lock.unlock()
        handler?(value)
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
            complete(.success(destination))
        } catch {
            complete(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        if let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            lock.lock(); storedResumeData = data; lock.unlock()
        }
        if (error as NSError).code == NSURLErrorCancelled {
            complete(.failure(ExerciseMediaTransferError.cancelled))
            return
        }
        complete(.failure(error))
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let handler = Self.backgroundCompletionHandler
        Self.backgroundCompletionHandler = nil
        handler?()
    }

    private func complete(_ result: Result<URL, Error>) {
        lock.lock()
        let handler = onCompletion
        onCompletion = nil
        onProgress = nil
        task = nil
        lock.unlock()
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
