import Foundation
import StrandAnalytics
import StrandCore
import WhoopStore

/// The Lab instruments of Training Load phase 2 (Q19, Q35), read from the store for the Lab card: the pulse at
/// the wearer's usual walking cadence, the pulse recovery after sessions that ended hard, and the pulse on flat
/// GPS kilometres at the usual pace, each with its check against an independent marker. Nothing here feeds a
/// verdict: an instrument only becomes evidence once `InstrumentCheck` has passed for the owner and a tester,
/// which is a decision made in the plan, not by the app.
enum TrainingInstrumentsReader {
    struct Instrument: Sendable {
        let reading: InstrumentReading
        /// The check against the reference with the most comparisons, and which reference it was.
        let check: InstrumentCheck.Result?
        let reference: String?
    }

    struct Snapshot: Sendable {
        let cadence: Instrument
        let recovery: Instrument
        let pace: Instrument
    }

    /// One recorded session as the payload stores it, only what the pace instrument reads.
    private struct Recording: Decodable {
        struct Row: Decodable { let startTs: Int }
        struct Timeline: Decodable {
            struct Split: Decodable { let startSeconds: Double; let endSeconds: Double; let distanceM: Double?; let ascentM: Double? }
            let splits: [Split]?
        }
        let row: Row
        let timeline: Timeline
    }

    static func read(reader: StoreReader, maxHR: Double, dismissedWorkoutSpans: [String], firstWeekday: Int,
                     appleVO2Weekly: [(start: String, value: Double)], days: [DailyMetric],
                     now: Int = Int(Date().timeIntervalSince1970)) async -> Snapshot {
        let offset = TimeZone.current.secondsFromGMT()
        let from = now - FitnessInstruments.windowDays * 86_400
        let fusion = await TrainingSessionResolver.read(reader: reader, from: from, to: now,
                                                        dismissedDetectedSpans: dismissedWorkoutSpans)
        let weekOf: (String) -> String = { TrainingGuidanceReader.weekStart($0, firstWeekday: firstWeekday) }
        var cadenceSessions: [(day: String, minutes: [FitnessInstruments.WalkMinute])] = []
        var recoverySessions: [(day: String, dropAfterOneMinute: Double)] = []
        for session in fusion.sessions where session.kind != .strength {
            let row = session.row
            guard row.endTs - row.startTs >= 600 else { continue }
            let day = AnalyticsEngine.dayString(row.startTs, offsetSec: offset)
            let hr = await reader.hrSamples(from: row.startTs, to: row.endTs + 6 * 60, limit: Int.max)
            if let r = HeartRateRecovery.calculate(samples: hr, workoutStart: row.startTs, workoutEnd: row.endTs,
                                                   maxHR: maxHR), let one = r.after1Minute {
                recoverySessions.append((day, Double(r.endHR - one)))
            }
            let label = row.sport.lowercased()
            guard label.contains("walk") || label.contains("geh") || label.contains("hik") else { continue }
            let steps = (try? await reader.store.stepSamples(deviceId: reader.activeDeviceId, from: row.startTs,
                                                              to: row.endTs, limit: Int.max)) ?? []
            let ticks = ActiveMinutes.ticksPerMinute(steps)
            var sums: [Int: (Int, Int)] = [:]
            for s in hr where s.ts <= row.endTs && s.bpm > 0 {
                let p = sums[s.ts / 60] ?? (0, 0); sums[s.ts / 60] = (p.0 + s.bpm, p.1 + 1)
            }
            let minutes = sums.compactMap { minute, sum -> FitnessInstruments.WalkMinute? in
                guard sum.1 >= ActiveMinutes.minimumSamplesPerMinute, let t = ticks[minute], t > 0 else { return nil }
                return FitnessInstruments.WalkMinute(cadence: t, bpm: Double(sum.0) / Double(sum.1))
            }
            if !minutes.isEmpty { cadenceSessions.append((day, minutes)) }
        }

        var paceSessions: [(day: String, splits: [FitnessInstruments.Split])] = []
        for sport in Set(fusion.sessions.map(\.row.sport)) {
            let payloads = (try? await reader.store.reduceWorkoutRecordingPayloads(
                sport: sport, before: now, initial: [String](), combine: { $0 + [$1] })) ?? []
            for payload in payloads {
                guard let data = payload.data(using: .utf8),
                      let recordings = try? JSONDecoder().decode([Recording].self, from: data) else { continue }
                for rec in recordings where rec.row.startTs >= from {
                    var splits: [FitnessInstruments.Split] = []
                    for split in rec.timeline.splits ?? [] {
                        guard let dist = split.distanceM, dist >= 900, split.endSeconds > split.startSeconds else { continue }
                        let start = rec.row.startTs + Int(split.startSeconds), end = rec.row.startTs + Int(split.endSeconds)
                        let hr = await reader.hrSamples(from: start, to: end, limit: Int.max).map(\.bpm).filter { $0 > 0 }
                        guard hr.count >= 60 else { continue }
                        splits.append(FitnessInstruments.Split(
                            secondsPerKm: (split.endSeconds - split.startSeconds) / (dist / 1000),
                            ascentM: split.ascentM ?? 0, bpm: Double(hr.reduce(0, +)) / Double(hr.count)))
                    }
                    if !splits.isEmpty {
                        paceSessions.append((AnalyticsEngine.dayString(rec.row.startTs, offsetSec: offset), splits))
                    }
                }
            }
        }

        let cadence = FitnessInstruments.pulseAtCadence(sessions: cadenceSessions, weekStart: weekOf)
        let recovery = FitnessInstruments.pulseRecovery(sessions: recoverySessions, weekStart: weekOf)
        let pace = FitnessInstruments.pulseAtPace(sessions: paceSessions, weekStart: weekOf)

        // References: Apple VO₂max (higher is fitter), the pace pulse (lower is fitter), the resting pulse
        // (lower is fitter), all as weekly medians.
        var restingByWeek: [String: [Double]] = [:]
        for d in days { if let r = d.restingHr { restingByWeek[weekOf(d.day), default: []].append(Double(r)) } }
        let resting = restingByWeek.keys.sorted().compactMap { k in
            FitnessInstruments.median(restingByWeek[k]!).map { (start: k, value: $0) } }
        typealias Reference = (name: String, line: [(start: String, value: Double)], higherIsBetter: Bool)
        let references: [Reference] = [("appleVO2max", appleVO2Weekly, true), ("pacePulse", pace.weeks, false),
                                       ("restingPulse", resting, false)]
        func checked(_ r: InstrumentReading, higherIsBetter: Bool, skip: String? = nil) -> Instrument {
            var best: (InstrumentCheck.Result, String)? = nil
            for ref in references where ref.name != skip && !ref.line.isEmpty {
                let result = InstrumentCheck.compare(instrument: r.weeks, instrumentHigherIsBetter: higherIsBetter,
                                                     reference: ref.line, referenceHigherIsBetter: ref.higherIsBetter)
                if best == nil || result.pairs > best!.0.pairs { best = (result, ref.name) }
            }
            return Instrument(reading: r, check: best?.0, reference: best?.1)
        }
        return Snapshot(cadence: checked(cadence, higherIsBetter: false),
                        recovery: checked(recovery, higherIsBetter: true),
                        pace: checked(pace, higherIsBetter: false, skip: "pacePulse"))
    }
}
