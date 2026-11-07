import Foundation

/// The session's daily passes, one at a time, beside the frame queue rather than inside it. A pass takes longer than
/// the Kotlin client waits for a history chunk to be banked (`CORE_ACK_WAIT_MS`), so a pass in the frame queue held
/// the chunks behind it, the client held their acks and the strap stopped sending: the 2026-11-05 field log shows
/// this in every one of a day's 237 offloads, with the strap's backlog growing throughout.
///
/// Requests that wait become one: the pass that finally runs reads everything stored by then, so it answers them all.
@MainActor
public final class AnalysisRuns {
    public struct Request: Sendable {
        public var profile: CoreAnalysis.Profile
        public var settings: CoreAnalysis.Settings
        public var deviceId: String
        public init(profile: CoreAnalysis.Profile, settings: CoreAnalysis.Settings, deviceId: String) {
            self.profile = profile; self.settings = settings; self.deviceId = deviceId
        }
    }

    private let pass: @MainActor (Request) async -> Void
    private var waiting: [(request: Request, ticket: Int)] = []
    private var worker: Task<Void, Never>?
    private var requested = 0
    private var finished = 0
    private var settledCallbacks: [(ticket: Int, completed: @Sendable () -> Void)] = []

    public init(pass: @escaping @MainActor (Request) async -> Void) { self.pass = pass }

    /// Queues a pass. A request for another strap keeps its own pass, and a whole-history request stays one when a
    /// later ordinary request joins it, since only the first asks for the days the second would leave alone.
    public func request(_ request: Request) {
        requested += 1
        if let last = waiting.last, last.request.deviceId == request.deviceId {
            var joined = request
            joined.settings.historyRescore = request.settings.historyRescore || last.request.settings.historyRescore
            waiting[waiting.count - 1] = (joined, requested)
        } else {
            waiting.append((request, requested))
        }
        guard worker == nil else { return }
        worker = Task { @MainActor in await work() }
    }

    /// Calls `completed` once every pass requested so far has stored its results; later requests do not extend it.
    public func whenSettled(_ completed: @escaping @Sendable () -> Void) {
        if finished >= requested { completed() } else { settledCallbacks.append((requested, completed)) }
    }

    public func settled() async {
        await withCheckedContinuation { continuation in whenSettled { continuation.resume() } }
    }

    private func work() async {
        while !waiting.isEmpty {
            let next = waiting.removeFirst()
            await pass(next.request)
            finished = next.ticket
            let done = settledCallbacks.filter { $0.ticket <= finished }
            settledCallbacks.removeAll { $0.ticket <= finished }
            done.forEach { $0.completed() }
        }
        worker = nil
    }
}
