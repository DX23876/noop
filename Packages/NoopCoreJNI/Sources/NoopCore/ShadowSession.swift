import Foundation
import StrandCore
import WhoopProtocol
import WhoopStore

/// The core running beside the Android app's own Kotlin pipeline (Android plan D-5, shadow step): the Kotlin
/// Bluetooth client hands every strap frame it receives to this session as well, and the core's Collector and
/// Backfiller decode and store them in the core's own store. Nothing here talks to the strap: the Backfiller's
/// trim acknowledgement is a no-op, because the Kotlin client still owns the link and acks history itself.
///
/// Calls arrive from Android's Bluetooth and IO threads. Each becomes an event on one stream, and a single task
/// on the main actor (where the Collector and Backfiller live) works through it in arrival order, so a history
/// chunk's START, records and END reach the Backfiller exactly as the strap sent them.
public enum ShadowSession {
    public enum Event: Sendable {
        case family(whoop5: Bool)
        case clock(device: Int, wall: Int)
        case live([UInt8])
        case offloadBegin(continuedAfterRows: Bool)
        case offload([UInt8])
        case flush
        /// Starts a new tally, in order with the frames: the Kotlin client resets its own counters per link.
        case resetTally
        /// Runs the daily analysis on the core's store with the wearer's profile; `today` holds the result.
        case analyze(CoreAnalysis.Profile, CoreAnalysis.Settings)
        /// Marks completion of the events queued before this callback.
        case barrier(@Sendable () -> Void)
    }

    /// What the core banked from history since the session started, per stream.
    public struct Tally: Sendable, Equatable {
        public var hr = 0, rr = 0, gravity = 0, spo2 = 0, skinTemp = 0, resp = 0, events = 0, battery = 0
        public var line: String {
            "hr=\(hr) rr=\(rr) gravity=\(gravity) spo2=\(spo2) skinTemp=\(skinTemp) resp=\(resp) events=\(events) battery=\(battery)"
        }
    }

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        /// Signalled whenever the core banks a history chunk; `awaitBanked` waits on it.
        let banked = NSCondition()
        /// The HISTORY_END data of the chunks the core banked most recently (persisted, cursor set), newest last.
        var bankedChunks: [[UInt8]] = []
        var continuation: AsyncStream<Event>.Continuation?
        var tally = Tally()
        var processed = 0
        var today: String?
        var store: WhoopStore?
        var path = ""
        var deviceId = ""
    }
    private static let state = State()

    /// Opens the core's store at `path` and starts the session for `deviceId`; a second call while one runs does
    /// nothing. Returns 0, or a negative value when the store cannot be opened. Blocks while the store opens.
    public static func start(path: String, deviceId: String) -> Int32 {
        state.lock.lock()
        let running = state.continuation != nil
        state.lock.unlock()
        if running { return 0 }
        final class Box: @unchecked Sendable { var store: WhoopStore? }
        let box = Box()
        let opened = DispatchSemaphore(value: 0)
        Task.detached {
            box.store = try? await WhoopStore(path: path)
            opened.signal()
        }
        opened.wait()
        guard let store = box.store else { return -1 }
        let (stream, continuation) = AsyncStream<Event>.makeStream(bufferingPolicy: .unbounded)
        state.lock.lock()
        state.continuation = continuation
        state.store = store
        state.path = path
        state.deviceId = deviceId
        state.tally = Tally()
        state.processed = 0
        state.lock.unlock()
        Task { @MainActor in
            await run(stream: stream, store: store, deviceId: deviceId)
        }
        return 0
    }

    /// Queues one event; dropped when no session runs.
    public static func send(_ event: Event) {
        state.lock.lock()
        let continuation = state.continuation
        state.lock.unlock()
        continuation?.yield(event)
    }

    /// Waits for events already queued, including analysis and its stored results. Call only from a
    /// background thread: the worker needs the main actor. False when no worker accepts the barrier.
    public static func awaitQueuedEvents() -> Bool {
        guard !Thread.isMainThread else { return false }
        let completed = DispatchSemaphore(value: 0)
        state.lock.lock()
        guard let continuation = state.continuation else { state.lock.unlock(); return false }
        let queued = continuation.yield(.barrier { completed.signal() })
        state.lock.unlock()
        guard case .enqueued = queued else { return false }
        completed.wait()
        return true
    }

    /// The history the core banked so far, and how many events it has worked through.
    public static var tally: Tally {
        state.lock.lock(); defer { state.lock.unlock() }
        return state.tally
    }

    /// A reader over the session's store for the screens (`CoreRead`); nil before a session started.
    public static var reader: StoreReader? {
        state.lock.lock(); defer { state.lock.unlock() }
        return state.store.map { StoreReader(store: $0, activeDeviceId: state.deviceId, registeredWhoopIds: []) }
    }

    /// The open store and the file it lives in, for the backup export and import; nil before a session started.
    public static var storeAndPath: (store: WhoopStore, path: String)? {
        state.lock.lock(); defer { state.lock.unlock() }
        return state.store.map { ($0, state.path) }
    }

    /// Today's scores from the last `analyze` event, as one line; nil before one ran or when today has no row.
    public static var today: String? {
        state.lock.lock(); defer { state.lock.unlock() }
        return state.today
    }

    public static var processedEvents: Int {
        state.lock.lock(); defer { state.lock.unlock() }
        return state.processed
    }

    /// How many banked chunks are remembered; more than an offload acks between two Kotlin acks.
    static let bankedMemory = 256

    private static func noteBanked(_ endData: [UInt8]) {
        state.banked.lock()
        state.bankedChunks.append(endData)
        if state.bankedChunks.count > bankedMemory { state.bankedChunks.removeFirst(state.bankedChunks.count - bankedMemory) }
        state.banked.broadcast()
        state.banked.unlock()
    }

    /// Waits up to `timeout` seconds for the core to have banked the history chunk whose HISTORY_END carries
    /// `endData`; true once it has. Blocks the calling thread, which on Android is the Kotlin offload drain, never
    /// the main thread the core's Backfiller runs on.
    public static func awaitBanked(endData: [UInt8], timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        state.banked.lock()
        defer { state.banked.unlock() }
        while !state.bankedChunks.contains(endData) {
            if !state.banked.wait(until: deadline) { return state.bankedChunks.contains(endData) }
        }
        return true
    }

    /// Ends the session after the events already queued.
    public static func stop() {
        state.lock.lock()
        let continuation = state.continuation
        state.continuation = nil
        state.lock.unlock()
        continuation?.finish()
    }

    @MainActor
    private static func run(stream: AsyncStream<Event>, store: WhoopStore, deviceId: String) async {
        let collector = Collector(store: store, deviceId: deviceId)
        let backfiller = Backfiller(
            store: store, deviceId: deviceId,
            // The Kotlin client owns the link and sends the ack. The Backfiller calls this only after the chunk is
            // persisted and its cursor set, so it marks the chunk banked; `awaitBanked` lets Kotlin hold its ack
            // until then (Android plan E-4, the safe-trim rule).
            ackTrim: { _, endData in noteBanked(endData) },
            onBankedOffload: { counts in
                state.lock.withLock {
                    state.tally.hr += counts.hr; state.tally.rr += counts.rr
                    state.tally.gravity += counts.gravity; state.tally.spo2 += counts.spo2
                    state.tally.skinTemp += counts.skinTemp; state.tally.resp += counts.resp
                    state.tally.events += counts.events; state.tally.battery += counts.battery
                }
            })
        var family = DeviceFamily.whoop4
        for await event in stream {
            switch event {
            case .family(let whoop5):
                family = whoop5 ? .whoop5 : .whoop4
                collector.family = family
                // Live frames carry real-unix seconds on a 5/MG; on a 4.0 the Kotlin client dates live records
                // by its own anchor, so the core uses the same identity reference until a clock arrives.
                if collector.clockRef == nil {
                    let now = Int(Date().timeIntervalSince1970)
                    collector.clockRef = ClockRef(device: now, wall: now)
                }
            case .clock(let device, let wall):
                backfiller.clockRef = ClockRef(device: device, wall: wall)
            case .live(let frame):
                collector.ingest(frame)
            case .offloadBegin(let continued):
                backfiller.begin(family: family, continuedAfterRows: continued)
            case .offload(let frame):
                await backfiller.ingest(frame)
            case .flush:
                await collector.flush()
            case .resetTally:
                state.lock.withLock { state.tally = Tally() }
            case .analyze(let profile, let settings):
                await collector.flush()
                let result = await CoreAnalysis.run(store: store, deviceId: deviceId, profile: profile, settings: settings)
                state.lock.withLock { state.today = result?.line ?? "no computed row for today" }
            case .barrier(let completed):
                completed()
            }
            state.lock.withLock { state.processed += 1 }
        }
        await collector.flush()
    }
}
