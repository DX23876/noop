import Foundation
import StrandCore
import WhoopStore

/// A cancellable import job. Polling never carries credentials or raw health documents back to the host.
actor CoreHevy {
    static let shared = CoreHevy()
    struct Status: Encodable {
        var id: String = "", state = "idle", phase: String = "", page = 0, totalPages = 0
        var summary: HevyImportSummary?
        var error: String?
        var storedWorkouts = 0
    }
    private var status = Status()
    private var task: Task<Void, Never>?

    func start(store: WhoopStore, key: String, routinesOnly: Bool = false) -> Status {
        guard status.state != "running" else {
            var busy = status; busy.error = HevyImportError.busy.rawValue; return busy
        }
        let id = UUID().uuidString
        status = Status(id: id, state: "running")
        task = Task {
            do {
                let engine = HevySyncEngine(fetcher: CoreHevyClient(key: key), store: store)
                let result: HevyImportSummary
                if routinesOnly {
                    var value = HevyImportSummary()
                    value.routines = try await engine.refreshRoutines().count
                    result = value
                } else {
                    result = try await engine.run { progress in
                        Task { await self.progress(id: id, value: progress) }
                    }
                }
                try Task.checkCancellation()
                let count = try await store.hevyWorkoutCount()
                self.finish(id: id, result: result, count: count)
            } catch is CancellationError { self.fail(id: id, code: "cancelled") }
            catch let error as HevyImportError { self.fail(id: id, code: error.rawValue) }
            catch { self.fail(id: id, code: "storeUnavailable") }
        }
        return status
    }
    func read() -> Status { status }
    func cancel(id: String) -> Status {
        if status.id == id, status.state == "running" { task?.cancel() }
        return status
    }
    func cancelAndWait() async {
        let running = task
        running?.cancel()
        await running?.value
    }
    private func progress(id: String, value: HevyImportProgress) {
        guard status.id == id, status.state == "running" else { return }
        status.phase = value.phase.rawValue; status.page = value.page; status.totalPages = value.totalPages
    }
    private func finish(id: String, result: HevyImportSummary, count: Int) {
        guard status.id == id else { return }
        status.state = "completed"; status.summary = result; status.storedWorkouts = count; task = nil
    }
    private func fail(id: String, code: String) {
        guard status.id == id else { return }
        status.state = code == "cancelled" ? "cancelled" : "failed"; status.error = code; task = nil
    }
}
