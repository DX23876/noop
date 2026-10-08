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
            case .waiting, .active, .contactLost, .restarting, .finishing: return true
            default: return false
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
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
    private var startedAt: Date?
    private var finishingSince: Date?
    private var ignoreFramesUntil: Date?
    private var timer: Timer?

    init(ble: BLEManager, repo: Repository) {
        self.ble = ble
        self.repo = repo
    }

    var isReady: Bool { ble.ecgReadingReady }

    /// Start a reading on `wrist`. `retry` spends the single inconclusive retry.
    func begin(wrist: Whoop5Ecg.WristSelection, retry: Bool = false) {
        guard !phase.isRunning else { return }
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
        ignoreFramesUntil = nil
        guard ble.ecgReadingReady else {
            phase = .failed
            failureReason = "notReady"
            return
        }
        ble.ecgReadingFrameSink = { [weak self] frame in self?.handle(frame) }
        guard ble.ecgReadingStart(wrist: wrist) else {
            ble.ecgReadingFrameSink = nil
            phase = .failed
            failureReason = "notReady"
            return
        }
        startedAt = Date()
        phase = .waiting
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
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
        pushLive(packet.samples)
        if phase == .finishing {
            if let variability = packet.variabilityRaw, let id = savedReadingId {
                ble.ecgReadingLog("variability \(variability) (raw) after the verdict")
                Task { [repo] in
                    if let store = await repo.storeHandle() {
                        try? await store.updateEcgReadingVariability(id: id, variabilityRaw: Int(variability))
                    }
                    await MainActor.run { self.savedRevision &+= 1 }
                }
                finish(.completed)
            }
            return
        }
        if let until = ignoreFramesUntil {
            if Date() < until { return }
            ignoreFramesUntil = nil
            if phase == .restarting { phase = .active }
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
                break
            case .sendRestart:
                phase = .restarting
                ignoreFramesUntil = Date().addingTimeInterval(1.5)
                ble.ecgReadingRestart()
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
        savedReadingId = id
        // The variability wait runs while the save lands; the cleanup waits for neither.
        phase = .finishing
        finishingSince = now
        Task { [repo, ble] in
            do {
                guard let store = await repo.storeHandle() else { throw CocoaError(.fileNoSuchFile) }
                try await store.saveEcgReading(row, packets: rows)
                ble.ecgReadingLog("saved \(id): \(stats.sampleCount) samples, \(stats.missingSegments) gap(s)")
                await MainActor.run { self.savedRevision &+= 1 }
            } catch {
                ble.ecgReadingLog("save failed: \(error.localizedDescription)")
                await MainActor.run {
                    self.savedReadingId = nil
                    if self.phase.isRunning { self.finish(.failed, reason: "save") } else {
                        self.phase = .failed
                        self.failureReason = "save"
                    }
                }
            }
        }
    }

    private func tick() {
        guard phase.isRunning, let startedAt else { return }
        elapsedSeconds = Int(Date().timeIntervalSince(startedAt))
        if phase == .finishing {
            if let since = finishingSince, Date().timeIntervalSince(since) >= Double(Self.variabilityWait) {
                finish(.completed)
            }
            return
        }
        if !ble.state.connected {
            finish(.failed, reason: "disconnected")
        } else if elapsedSeconds >= Self.captureTimeout {
            finish(.failed, reason: progress == 0 && liveSamples.isEmpty ? "noData" : "timeout")
        }
    }

    /// The one exit path: cleanup is sent once, the sink and the timer are released, then the phase is set.
    private func finish(_ final: Phase, reason: String? = nil) {
        timer?.invalidate()
        timer = nil
        ble.ecgReadingFrameSink = nil
        if ble.state.connected {
            ble.ecgReadingStop()
        } else {
            ble.ecgReadingLog("link down; the strap may still be generating, so Stop stays offered")
        }
        if let reason { ble.ecgReadingLog("ended: \(reason)") }
        failureReason = reason
        phase = final
    }
}
