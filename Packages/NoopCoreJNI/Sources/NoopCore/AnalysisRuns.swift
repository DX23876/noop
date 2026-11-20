import Foundation

/// The session's daily passes, one at a time, beside the frame queue rather than inside it. A pass takes longer than
/// the Kotlin client waits for a history chunk to be banked (`CORE_ACK_WAIT_MS`), so a pass in the frame queue held
/// the chunks behind it, the client held their acks and the strap stopped sending: the 2026-11-05 field log shows
/// this in every one of a day's 237 offloads, with the strap's backlog growing throughout.
///
/// Requests that wait become one: the pass that finally runs reads everything stored by then, so it answers them all.
///
/// Out of the queue is not off the actor, though, and that was not enough: a pass holds the main actor for far
/// longer than ten seconds, so the frames behind it were still not banked in time and the 2026-11-18 field log
/// showed the same loop again (#53, finding 1). So a pass also waits while the strap is handing history over
/// (`hold`, fed by `OffloadWatch`). Waiting costs the wearer nothing - these are a day's figures, not a second's -
/// and the handover it yields to is a burst of a few chunks.
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
    /// True while the strap is handing history over and the pass should wait.
    private let hold: @MainActor () -> Bool
    /// How often the hold is re-read. Small enough that the pass starts promptly once the burst ends.
    private let pollStep: Duration
    private var waiting: [(request: Request, ticket: Int)] = []
    private var worker: Task<Void, Never>?
    private var requested = 0
    private var finished = 0
    private var settledCallbacks: [(ticket: Int, completed: @Sendable () -> Void)] = []

    public init(hold: @escaping @MainActor () -> Bool = { false },
                pollStep: Duration = .milliseconds(250),
                pass: @escaping @MainActor (Request) async -> Void) {
        self.hold = hold
        self.pollStep = pollStep
        self.pass = pass
    }

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
            // Yield to the strap first. Sleeping hands the actor back, which is the whole point: the frame
            // loop runs, the chunks are banked and the client's acks go out on time.
            while hold() { try? await Task.sleep(for: pollStep) }
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
