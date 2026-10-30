import Foundation

/// The ordered queue of offload frames and the one task that drains it into the Backfiller. Frames are
/// appended synchronously (delegate order) and drained sequentially in small slices, so START / data / END
/// chunk assembly is never reordered while the UI still gets time to paint.
///
/// Single-flight holds across links too. An ingest can suspend (a chunk's END awaits its store write) while
/// the link drops and the next one starts an offload. Clearing a plain draining flag at the teardown let the
/// next link's first frame start a second drain beside the suspended one, so two ingests ran at once and the
/// old drain, on resuming, carried on with frames of the new link. Now the next link's drain waits for the old
/// one, and the old one stops at its first resume without touching the queue or the draining flag, which
/// belong to the next link by then. Adapted from ayiskakov/noop (W06-008); the Android twin is
/// `BackfillDrainGate`.
@MainActor
final class BackfillDrain {
    private var queue: [[UInt8]] = []
    /// True while this link's drain task is running (prevents a second drain task from launching).
    private var draining = false
    /// Counts links; bumped when one ends. A drain started on an earlier link stops at its next resume.
    private var link = 0
    /// The drain task most recently started, which the next link's drain waits for.
    private var lastDrain: Task<Void, Never>?
    /// The link the ingest in flight began on; nil between ingests.
    private var ingestLink: Int?
    /// Drain tasks started and not yet finished, across links.
    private var runningDrains = 0
    private let batchSize: Int
    private let ingest: ([UInt8]) async -> Void
    /// Called after every ingest; false ends the drain and drops what is still queued (the session ended).
    private let afterIngest: () -> Bool
    private let log: (String) -> Void

    init(batchSize: Int, ingest: @escaping ([UInt8]) async -> Void, afterIngest: @escaping () -> Bool,
         log: @escaping (String) -> Void = { _ in }) {
        self.batchSize = batchSize
        self.ingest = ingest
        self.afterIngest = afterIngest
        self.log = log
    }

    /// True while an ingest that began on a link that has since ended is still running. Whatever it asks to
    /// send, a chunk's ack above all, belongs to that link and not to the one now up.
    var ingestOutlivedItsLink: Bool { ingestLink.map { $0 != link } ?? false }

    func route(_ frame: [UInt8]) {
        queue.append(frame)
        guard !draining else { return }
        draining = true
        let previous = lastDrain
        let started = link
        if runningDrains > 0 {
            // Always-on (rare): an ingest that never returned would otherwise stall every later offload until
            // its idle timeout, which would blame a quiet strap.
            log("Backfill: this link's offload waits for the previous link's drain, still in an ingest")
        }
        runningDrains += 1
        lastDrain = Task { @MainActor in
            await previous?.value
            await self.drain(link: started)
            self.runningDrains -= 1
        }
    }

    /// The offload session ended: drop what is queued.
    func dropQueued() {
        queue.removeAll()
    }

    /// The link ended. Its queued frames go; a drain still suspended in an ingest stops when that returns.
    func linkEnded() {
        queue.removeAll()
        draining = false
        link &+= 1
    }

    /// Resolves once every drain started so far has finished. For tests.
    func settle() async {
        await lastDrain?.value
    }

    private func drain(link started: Int) async {
        while !queue.isEmpty {
            // The link ended while this drain waited for the previous one: the queue is the next link's.
            guard link == started else { return }
            let count = min(batchSize, queue.count)
            let batch = Array(queue.prefix(count))
            queue.removeFirst(count)

            for (i, f) in batch.enumerated() {
                ingestLink = started
                await ingest(f)
                ingestLink = nil
                guard link == started else {
                    // Rare-event evidence: the only trace of an ingest that outlived its link.
                    let dropped = batch.count - i - 1
                    log("Backfill: the link ended during an ingest; its drain stops here"
                        + (dropped > 0 ? " and \(dropped) frame(s) of that link are not ingested" : ""))
                    return
                }
                if !afterIngest() {
                    queue.removeAll(keepingCapacity: true)
                    break
                }
            }

            if !queue.isEmpty {
                await Task.yield()
            }
        }
        if link == started { draining = false }
    }
}
