import Foundation
import WhoopProtocol
import WhoopStore

/// The lifecycle owner of one WHOOP MG ECG reading, ported from OpenStrap Edge's `EcgController`
/// (MIT, Copyright (c) 2026 OpenStrap; `lib/ecg/ecg_controller.dart`, release v0.10.0).
///
/// It sends PREPARE and START through `BLEManager`, feeds every live R17 packet through the pure
/// `EcgReadingState` reducer, saves a completed reading with its accepted window, and runs the cleanup
/// on every exit. Two deliberate differences from OpenStrap:
///
/// - After the verdict it keeps listening for up to `variabilityWait` seconds, because the strap only
///   reports its variability field a few seconds after the terminal packet (#891). The reading is saved
///   first, so a drop in that window loses nothing but the variability.
/// - It does not stop when the app leaves the foreground: the link stays up in the background on iOS,
///   and the wearer is holding the clasp either way.
///
/// The result is the strap's own. NOOP is not a medical device and nothing here is a diagnosis.
@MainActor
final class EcgReadingController: ObservableObject {

    enum Phase: Equatable {
        case idle
        case preparing
        case stopping
        /// Commands sent, waiting for the first packet with electrode contact.
        case waiting
        case active
        case contactLost
        case restarting
        /// Verdict received and saved; waiting a few seconds for the variability field.
        case finishing
        case completed
        case unreadable
        case inconclusiveRetry
        case cancelled
        case failed

        var isRunning: Bool {
            switch self {
            case .preparing, .waiting, .active, .contactLost, .restarting, .finishing, .stopping: return true
            default: return false
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var cleanupIncomplete = false
    @Published private(set) var progress = 0
    @Published private(set) var liveHr: Int?
    @Published private(set) var quality = 0
    @Published private(set) var interruptions = 0
    @Published private(set) var failureReason: String?
    @Published private(set) var unreadableMask: UInt8 = 0
    @Published private(set) var savedReadingId: String?
    /// The last eight seconds of live samples (100 Hz), oldest first. RAM only.
    @Published private(set) var liveSamples: [Int16] = []
    @Published private(set) var elapsedSeconds = 0
    /// Bumped after every save, so a list of saved readings knows to reload.
    @Published private(set) var savedRevision = 0

    static let liveCapacity = 800
    /// OpenStrap's capture timeout. A verdict normally arrives about 40 s after contact.
    static let captureTimeout = 120
    static let variabilityWait = 12

    private let ble: BLEManager
    private let repo: Repository
    private var reducer = EcgReadingState()
    private var wrist: Whoop5Ecg.WristSelection = .left
    private var retriesUsed = 0
    private var windowStart: Date?
    private var startedAt: TimeInterval?
    private var finishingSince: TimeInterval?
    private var completion = EcgReadingCompletion()
    private var finalPhase: Phase = .cancelled
    private var finalReason: String?
    private var pendingVariability: Int?
    private var storedVariability: Int?
    private let clock: () -> TimeInterval
    private var timer: Timer?

    init(ble: BLEManager, repo: Repository, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.ble = ble
        self.repo = repo
        self.clock = clock
    }

    var isReady: Bool { ble.ecgReadingReady }

    /// Start a reading on `wrist`. `retry` spends the single inconclusive retry.
    func begin(wrist: Whoop5Ecg.WristSelection, retry: Bool = false) {
        guard !phase.isRunning else { return }
        let run = completion.begin()
        self.wrist = wrist
        retriesUsed = retry ? 1 : 0
        reducer = EcgReadingState(retriesUsed: retriesUsed)
        progress = 0
        liveHr = nil
        quality = 0
        interruptions = 0
        failureReason = nil
        unreadableMask = 0
        savedReadingId = nil
        liveSamples = []
        elapsedSeconds = 0
        windowStart = nil
        finishingSince = nil
        cleanupIncomplete = false
        pendingVariability = nil
        storedVariability = nil
        guard ble.ecgReadingReady else {
            phase = .failed
            failureReason = "notReady"
            return
        }
        phase = .preparing
        startedAt = clock()
        ble.ecgReadingFrameSink = { [weak self] frame in self?.handle(frame) }
        ble.ecgReadingDisconnectSink = { [weak self] in
            guard let self else { return }
            self.finish(self.savedReadingId != nil || self.completion.saving ? .completed : .failed,
                        reason: self.savedReadingId != nil || self.completion.saving ? nil : "disconnected")
        }
        ble.ecgReadingCancelSink = { [weak self] in self?.cancel() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        Task { [weak self] in
            guard let self else { return }
            let started = await self.ble.ecgReadingStart(wrist: wrist)
            guard self.completion.isCurrent(run), self.phase == .preparing else { return }
            if started { self.phase = .waiting } else { self.finish(.failed, reason: "prepare") }
        }
    }

    func retry() {
        guard phase == .inconclusiveRetry else { return }
        begin(wrist: wrist, retry: true)
    }

    func cancel() {
        guard phase.isRunning else { return }
        if phase == .finishing {
            finish(.completed)
        } else {
            finish(.cancelled, reason: "cancelled")
        }
    }

    /// Back to idle after a finished reading (sheet closed).
    func reset() {
        guard !phase.isRunning else { return }
        phase = .idle
    }

    // MARK: - Frames

    private func handle(_ frame: [UInt8]) {
        guard phase.isRunning, let packet = Whoop5Ecg.r17FromFrame(frame) else { return }
        guard phase != .preparing, phase != .restarting, phase != .stopping else { return }
        pushLive(packet.samples)
        if phase == .finishing {
            if let value = packet.variabilityRaw { pendingVariability = Int(value) }
            finishSavedIfReady()
            return
        }
        let wasEmpty = reducer.accepted.isEmpty
        let step = reducer.reduce(packet)
        reducer = step.state
        if wasEmpty, !reducer.accepted.isEmpty { windowStart = Date() }
        if packet.progress.raw != 255 { progress = Int(packet.progress.raw) }
        liveHr = packet.liveHR > 0 ? Int(packet.liveHR) : nil
        quality = Int(packet.signalQualityRaw)
        interruptions = reducer.interruptions
        switch reducer.phase {
        case .waiting: phase = .waiting
        case .active: phase = .active
        case .contactLost: phase = .contactLost
        case .done: break
        }
        for effect in step.effects {
            switch effect {
            case .clear:
                if reducer.accepted.isEmpty { windowStart = nil }
            case .sendRestart:
                phase = .restarting
                let run = completion.generation
                Task { [weak self] in
                    guard let self else { return }
                    let restarted = await self.ble.ecgReadingRestart()
                    guard self.completion.isCurrent(run), self.phase == .restarting else { return }
                    if restarted { self.phase = .active } else { self.finish(.failed, reason: "restart") }
                }
            case .fail(let reason):
                finish(.failed, reason: reason)
            case .terminal(let outcome):
                handleTerminal(outcome)
            }
        }
    }

    private func pushLive(_ samples: [Int16]) {
        guard !samples.isEmpty else { return }
        var ring = liveSamples
        ring.append(contentsOf: samples)
        if ring.count > Self.liveCapacity { ring.removeFirst(ring.count - Self.liveCapacity) }
        liveSamples = ring
    }

    private func handleTerminal(_ outcome: EcgTerminalOutcome) {
        let t = outcome.terminal
        ble.ecgReadingLog("verdict kind=\(outcome.kind.rawValue) resultRaw=\(t.arrhythmiaCheckResultRaw) "
                          + "avgHr=\(t.averageHR) liveHr=\(t.liveHR) quality=\(t.signalQualityRaw) "
                          + "unreadable=0x\(String(t.unreadable.raw, radix: 16)) "
                          + "interruptions=\(reducer.interruptions) after \(elapsedSeconds) s")
        switch outcome.kind {
        case .unreadable:
            unreadableMask = t.unreadable.raw
            finish(.unreadable)
        case .inconclusiveOfferRetry:
            finish(.inconclusiveRetry)
        case .completed, .inconclusiveFinal:
            save(outcome)
        }
    }

    private func save(_ outcome: EcgTerminalOutcome) {
        let t = outcome.terminal
        let packets = reducer.accepted
        let stats = EcgWindowStats(packets)
        let now = Date()
        let start = windowStart ?? now
        let id = "ecg_\(Int(start.timeIntervalSince1970 * 1000))_\(t.strapSeconds)"
        let row = EcgReadingRow(
            id: id, deviceId: ble.ecgReadingDeviceId, wrist: wrist.token,
            startTs: Int(start.timeIntervalSince1970), endTs: Int(now.timeIntervalSince1970),
            strapTerminalTs: Int(t.strapSeconds), resultCode: Int(t.arrhythmiaCheckResultRaw),
            category: outcome.savedCategory.rawValue, averageHr: t.averageHR > 0 ? Int(t.averageHR) : nil,
            variabilityRaw: t.variabilityRaw.map(Int.init), quality: Int(t.signalQualityRaw),
            unreadableMask: Int(t.unreadable.raw), interruptions: reducer.interruptions,
            sampleCount: stats.sampleCount, missingSegments: stats.missingSegments,
            status: outcome.kind == .inconclusiveFinal ? "inconclusive" : "completed")
        let rows = packets.map {
            EcgReadingPacketRow(sequence: Int($0.sequence),
                                strapSeconds: $0.isPlaceholder ? nil : Int($0.strapSeconds),
                                strapSubseconds: $0.isPlaceholder ? nil : Int($0.strapSubseconds),
                                isPlaceholder: $0.isPlaceholder, samples: $0.samples)
        }
        let run = completion.generation
        pendingVariability = row.variabilityRaw
        storedVariability = row.variabilityRaw
        phase = .finishing
        finishingSince = clock()
        completion.beginSave()
        Task { [repo, ble] in
            do {
                guard let store = await repo.storeHandle() else { throw CocoaError(.fileNoSuchFile) }
                try await store.saveEcgReading(row, packets: rows)
                guard self.completion.saved(run) else { return }
                self.savedReadingId = id
                self.savedRevision &+= 1
                ble.ecgReadingLog("saved \(id): \(stats.sampleCount) samples, \(stats.missingSegments) gap(s)")
                if self.completion.finishing { self.publishFinished() } else { self.finishSavedIfReady() }
            } catch {
                guard self.completion.saved(run) else { return }
                ble.ecgReadingLog("save failed: \(error.localizedDescription)")
                self.savedReadingId = nil
                self.finalPhase = .failed
                self.finalReason = "save"
                if self.completion.finishing { self.publishFinished() } else { self.finish(.failed, reason: "save") }
            }
        }
    }

    /// The HRV update is ordered after the initial insert; it cannot silently update a nonexistent row.
    private func finishSavedIfReady() {
        guard phase == .finishing, !completion.saving, let id = savedReadingId else { return }
        let expired = finishingSince.map { clock() - $0 >= Double(Self.variabilityWait) } ?? false
        guard pendingVariability != nil || expired else { return }
        guard let value = pendingVariability, value != storedVariability else { finish(.completed); return }
        let run = completion.generation
        completion.beginSave()
        Task { [repo] in
            do {
                guard let store = await repo.storeHandle() else { throw CocoaError(.fileNoSuchFile) }
                try await store.updateEcgReadingVariability(id: id, variabilityRaw: value)
                guard self.completion.saved(run) else { return }
                self.storedVariability = value
                self.savedRevision &+= 1
            } catch {
                guard self.completion.saved(run) else { return }
                self.ble.ecgReadingLog("variability update failed; original reading retained")
            }
            if self.completion.finishing { self.publishFinished() } else { self.finish(.completed) }
        }
    }

    private func tick() {
        guard phase.isRunning, let startedAt else { return }
        elapsedSeconds = max(0, Int(clock() - startedAt))
        if !ble.state.connected {
            finish(savedReadingId != nil || completion.saving ? .completed : .failed,
                   reason: savedReadingId != nil || completion.saving ? nil : "disconnected")
        } else if phase == .finishing {
            finishSavedIfReady()
        } else if elapsedSeconds >= Self.captureTimeout {
            finish(.failed, reason: progress == 0 && liveSamples.isEmpty ? "noData" : "timeout")
        }
    }

    /// Releases the stream immediately, attempts every OFF command once, and publishes the outcome
    /// after both persistence and cleanup settle. No new reading can start in this interval.
    private func finish(_ final: Phase, reason: String? = nil) {
        guard completion.requestFinish() else { return }
        finalPhase = final
        finalReason = reason
        phase = .stopping
        timer?.invalidate()
        timer = nil
        ble.ecgReadingFrameSink = nil
        ble.ecgReadingDisconnectSink = nil
        ble.ecgReadingCancelSink = nil
        let run = completion.generation
        Task { [ble] in
            let stopped = await ble.ecgReadingStop()
            guard self.completion.isCurrent(run) else { return }
            self.completion.cleanedUp(run, success: stopped)
            self.publishFinished()
        }
    }

    private func publishFinished() {
        guard completion.canPublish else { return }
        cleanupIncomplete = completion.cleanupSucceeded != true
        failureReason = finalReason
        phase = finalPhase
    }
}
