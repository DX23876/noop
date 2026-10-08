import Foundation

/// Measurements from one single-lead ECG strip, as the WHOOP MG records it: 100 Hz filtered samples in
/// (nominal) microvolts, about 30 s long, taken between the wrist and a finger of the other hand.
///
/// The pipeline follows what ECG software commonly does, scaled to what one lead at 100 Hz supports:
///
/// 1. Baseline removal with two cascaded median filters (200 ms, then 600 ms), the de Chazal approach:
///    it removes wander without bending the P and T waves the way a plain moving mean does.
/// 2. QRS detection on slope energy (derivative, squared, 150 ms moving window), the core of
///    Pan-Tompkins, with a 250 ms refractory period. The R peak is then placed on the trace itself, and
///    the dominant QRS polarity is detected so an inverted lead still measures.
/// 3. Rhythm: RR intervals, irregular beats (an RR more than 20 % off its local median), and HRV
///    (RMSSD, SDNN, pNN50) over normal-to-normal intervals only.
/// 4. A median beat from the regular beats that correlate with it (r >= 0.9). Averaging is what makes
///    the small P and T waves measurable on a wrist lead.
/// 5. Fiducial points on the median beat: QRS onset and J point by slope threshold, P onset and T end by
///    the tangent method; PR, QRS, QT, and QTc by Fridericia (and Bazett for reference).
///
/// Limits that stay true whatever the code does: 100 Hz sampling gives about 10 ms of resolution (a
/// diagnostic ECG samples at 500 Hz or more), one lead gives no electrical axis and no localisation, and
/// the strap's own filter and amplitude scale are not verified. Every interval is a nominal estimate, not
/// a clinical measurement, and nothing here is a diagnosis.
public enum EcgAnalysis {

    /// Points on the median beat, in milliseconds relative to the R peak.
    public struct Fiducials: Equatable, Sendable {
        public let pOnsetMs: Double?
        public let pPeakMs: Double?
        public let qrsOnsetMs: Double
        public let jPointMs: Double
        public let tPeakMs: Double?
        public let tEndMs: Double?
    }

    public struct Result: Equatable, Sendable {
        public let beatsDetected: Int
        public let irregularBeats: Int
        public let meanHeartRate: Double
        public let minHeartRate: Double
        public let maxHeartRate: Double
        public let rmssdMs: Double?
        public let sdnnMs: Double?
        /// Percent of successive normal-to-normal differences above 50 ms.
        public let pnn50: Double?
        /// The dominant QRS deflection is negative (a reversed lead or the other wrist).
        public let inverted: Bool
        /// Beats that went into the median beat.
        public let beatsAveraged: Int
        /// Median correlation of the averaged beats with the median beat, 0 to 1.
        public let templateCorrelation: Double?
        /// The median beat in microvolts at the input rate, polarity as recorded.
        public let template: [Double]
        /// Index of the R peak in `template`.
        public let templateRIndex: Int
        public let fiducials: Fiducials?
        public let prMs: Double?
        public let qrsMs: Double?
        public let qtMs: Double?
        public let qtcFridericiaMs: Double?
        public let qtcBazettMs: Double?
    }

    /// Fewer regular beats than this and no median beat (or interval) is reported.
    public static let minimumBeats = 8
    static let correlationFloor = 0.9

    public static func analyze(_ samples: [Int16?], sampleRate: Int = 100) -> Result? {
        guard sampleRate == 100, samples.count >= sampleRate * 8 else { return nil }
        let fs = Double(sampleRate)
        func n(_ seconds: Double) -> Int { max(1, Int((seconds * fs).rounded())) }

        // Digital saturation and isolated, extreme impulses must not set the detection threshold.
        // Scale is relative to the strip: the device's physical amplitude calibration is unknown.
        let present = samples.compactMap { $0.map(Double.init) }
        guard !present.isEmpty else { return nil }
        let centre = median(present)
        let amplitude = percentile(present.map { abs($0 - centre) }, 0.99)
        guard amplitude > 0 else { return nil }
        var clean = samples
        for k in samples.indices {
            guard let raw = samples[k] else { continue }
            if abs(Int(raw)) >= 32_760 || abs(Double(raw) - centre) > 6 * amplitude {
                for j in max(0, k - n(0.08))...min(samples.count - 1, k + n(0.08)) { clean[j] = nil }
            }
        }

        // 1. Baseline removal, per contiguous run (a lost packet is a gap, never bridged).
        var y = [Double?](repeating: nil, count: samples.count)
        var runs: [Range<Int>] = []
        var i = 0
        while i < samples.count {
            guard clean[i] != nil else { i += 1; continue }
            var end = i
            while end < samples.count, clean[end] != nil { end += 1 }
            let run = (i..<end).map { Double(clean[$0]!) }
            if run.count >= n(2) {
                let baseline = medianFilter(medianFilter(run, width: n(0.2) | 1), width: n(0.6) | 1)
                for k in run.indices { y[i + k] = run[k] - baseline[k] }
                runs.append(i..<end)
            }
            i = end
        }
        guard !runs.isEmpty else { return nil }

        // 2. QRS detection on slope energy, then R placed on the trace.
        var candidates: [(index: Int, signed: Double, run: Int)] = []
        for (runIndex, run) in runs.enumerated() {
            let x = run.map { y[$0]! }
            var energy = [Double](repeating: 0, count: x.count)
            for k in 2..<max(2, x.count) {
                let d = x[k] - x[k - 2]
                energy[k] = d * d
            }
            let window = n(0.15)
            var mwi = [Double](repeating: 0, count: x.count)
            var acc = 0.0
            for k in energy.indices {
                acc += energy[k]
                if k >= window { acc -= energy[k - window] }
                mwi[k] = acc / Double(window)
            }
            let threshold = 0.2 * percentile(mwi, 0.98)
            guard threshold > 0 else { continue }
            var peaks: [Int] = []
            for k in 1..<max(1, mwi.count - 1) where mwi[k] > threshold && mwi[k] >= mwi[k - 1] && mwi[k] > mwi[k + 1] {
                if let last = peaks.last, k - last < n(0.25) {
                    if mwi[k] > mwi[last] { peaks[peaks.count - 1] = k }
                } else {
                    peaks.append(k)
                }
            }
            for peak in peaks {
                let lo = max(0, peak - n(0.2))
                let r = (lo...peak).max { abs(x[$0]) < abs(x[$1]) } ?? peak
                candidates.append((run.lowerBound + r, x[r], runIndex))
            }
        }
        guard candidates.count >= 3 else { return nil }
        let polarity: Double = median(candidates.map(\.signed)) < 0 ? -1 : 1
        // Re-place each R on the dominant deflection, so a deep S never stands in for the R.
        var beats: [(index: Int, run: Int)] = []
        for c in candidates {
            let lo = max(runs[c.run].lowerBound, c.index - n(0.06))
            let hi = min(runs[c.run].upperBound - 1, c.index + n(0.06))
            let r = (lo...hi).max { polarity * y[$0]! < polarity * y[$1]! } ?? c.index
            if let last = beats.last, last.run == c.run, r - last.index < n(0.25) { continue }
            beats.append((r, c.run))
        }

        // 3. Rhythm and HRV. Intervals never span a gap.
        var rr: [(ms: Double, beat: Int)] = []
        for k in 1..<beats.count where beats[k].run == beats[k - 1].run {
            rr.append((Double(beats[k].index - beats[k - 1].index) * 1000 / fs, k))
        }
        guard !rr.isEmpty else { return nil }
        var irregular = Set<Int>()       // indices into `rr`
        for k in rr.indices {
            let neighbours = rr[max(0, k - 4)..<k].map(\.ms) + rr[min(rr.count, k + 1)..<min(rr.count, k + 5)].map(\.ms)
            guard !neighbours.isEmpty else { continue }
            let local = median(neighbours)
            if abs(rr[k].ms - local) > 0.2 * local { irregular.insert(k) }
        }
        let normal = rr.indices.filter { !irregular.contains($0) && !irregular.contains($0 - 1) }
        let nn = normal.map { rr[$0].ms }
        var successive: [Double] = []
        for k in normal where normal.contains(k - 1) && rr[k].beat - 1 == rr[k - 1].beat {
            successive.append(rr[k].ms - rr[k - 1].ms)
        }
        let allRR = rr.map(\.ms)
        let rateBasis = nn.isEmpty ? allRR : nn
        let meanRR = allRR.reduce(0, +) / Double(allRR.count)
        let rmssd = successive.count >= 2
            ? (successive.map { $0 * $0 }.reduce(0, +) / Double(successive.count)).squareRoot() : nil
        let sdnn: Double? = nn.count >= 3 ? standardDeviation(nn) : nil
        let pnn50: Double? = successive.count >= 2
            ? 100 * Double(successive.filter { abs($0) > 50 }.count) / Double(successive.count) : nil

        // 4. Median beat from the regular beats that look like it.
        let pre = n(0.35), post = n(0.55)
        // Every beat is a candidate, irregular timing included: a premature beat with a different shape
        // fails the correlation below, while an irregular rhythm (atrial fibrillation) keeps normal QRS
        // shapes and must still get a median beat. Excluding by timing would leave such a strip without
        // any rhythm values at all, because the shape gate below requires a median beat.
        var windows: [[Double]] = []
        for beat in beats {
            let run = runs[beat.run]
            guard beat.index - pre >= run.lowerBound, beat.index + post < run.upperBound else { continue }
            let iso = median((beat.index - n(0.07)...beat.index - n(0.03)).map { y[$0]! })
            windows.append((beat.index - pre...beat.index + post).map { y[$0]! - iso })
        }
        var template: [Double] = []
        var averaged = 0
        var correlation: Double?
        if windows.count >= minimumBeats {
            let first = columnMedian(windows)
            let scored = windows.map { (window: $0, r: pearson($0, first)) }
            let kept = scored.filter { $0.r >= correlationFloor }
            if kept.count >= minimumBeats {
                template = columnMedian(kept.map(\.window))
                averaged = kept.count
                correlation = median(kept.map(\.r))
            }
        }

        // Repeated shape agreement is required for rhythm too. Random noise can produce energy peaks
        // and plausible RR intervals; it must not receive HR/HRV merely because it crossed a threshold.
        guard !template.isEmpty, (300...2000).contains(median(allRR)) else { return nil }

        // 5. Fiducials and intervals on the median beat.
        var fiducials: Fiducials?
        var pr: Double?, qrs: Double?, qt: Double?, qtcF: Double?, qtcB: Double?
        if !template.isEmpty {
            fiducials = locateFiducials(template.map { polarity * $0 }, rIndex: pre, fs: fs, meanRRms: meanRR)
            if let f = fiducials {
                let rrSeconds = (nn.isEmpty ? meanRR : nn.reduce(0, +) / Double(nn.count)) / 1000
                if let pOn = f.pOnsetMs { pr = within(f.qrsOnsetMs - pOn, 80...320) }
                qrs = within(f.jPointMs - f.qrsOnsetMs, 40...200)
                if let tEnd = f.tEndMs, let value = within(tEnd - f.qrsOnsetMs, 200...650) {
                    qt = value
                    qtcF = value / pow(rrSeconds, 1.0 / 3.0)
                    qtcB = value / rrSeconds.squareRoot()
                }
            }
        }

        let rates = rateBasis.map { 60_000 / $0 }
        return Result(beatsDetected: beats.count, irregularBeats: irregular.count,
                      meanHeartRate: 60_000 / meanRR, minHeartRate: rates.min() ?? 0,
                      maxHeartRate: rates.max() ?? 0, rmssdMs: rmssd, sdnnMs: sdnn, pnn50: pnn50,
                      inverted: polarity < 0, beatsAveraged: averaged, templateCorrelation: correlation,
                      template: template, templateRIndex: pre, fiducials: fiducials, prMs: pr, qrsMs: qrs,
                      qtMs: qt, qtcFridericiaMs: qtcF, qtcBazettMs: qtcB)
    }

    // MARK: - Fiducial points

    /// `z` is the median beat with its R pointing up. Searches run on a 4x linear upsample, which places a
    /// threshold crossing between samples; it does not add information the 100 Hz trace does not carry.
    static func locateFiducials(_ z: [Double], rIndex: Int, fs: Double, meanRRms: Double) -> Fiducials? {
        let up = 4
        var u: [Double] = []
        u.reserveCapacity(z.count * up)
        for k in 0..<(z.count - 1) {
            for j in 0..<up { u.append(z[k] + (z[k + 1] - z[k]) * Double(j) / Double(up)) }
        }
        u.append(z[z.count - 1])
        let r0 = rIndex * up
        func s(_ seconds: Double) -> Int { Int((seconds * fs * Double(up)).rounded()) }
        func ms(_ index: Double) -> Double { (index - Double(r0)) * 1000 / (fs * Double(up)) }
        var slope = [Double](repeating: 0, count: u.count)
        for k in 1..<(u.count - 1) { slope[k] = (u[k + 1] - u[k - 1]) / 2 }
        func clamp(_ k: Int) -> Int { min(max(k, 1), u.count - 2) }

        let qrsLo = clamp(r0 - s(0.12)), qrsHi = clamp(r0 + s(0.12))
        let slopeMax = (qrsLo...qrsHi).map { abs(slope[$0]) }.max() ?? 0
        guard slopeMax > 0, u[r0] > 0 else { return nil }
        let flat = 0.1 * slopeMax

        var qrsOn: Int?
        for k in stride(from: r0, through: clamp(r0 - s(0.15)) + 1, by: -1)
            where abs(slope[k]) < flat && abs(slope[k - 1]) < flat { qrsOn = k; break }
        let minimum = (r0...clamp(r0 + s(0.08))).min { u[$0] < u[$1] } ?? r0
        // A monophasic QRS has no S trough. Searching from its window minimum otherwise starts at
        // +80 ms, after the actual end of the descending R flank.
        let sTrough = u[minimum] < -0.08 * u[r0] ? minimum : r0
        var jPoint: Int?
        for k in sTrough..<clamp(r0 + s(0.18)) where abs(slope[k]) < flat
            && abs(slope[k + 1]) < flat && abs(u[k]) < 0.15 * u[r0] {
            jPoint = k; break
        }
        guard let qrsOn, let jPoint else { return nil }

        // T wave: the largest deflection after the J point, ending before the next beat could start.
        let rAmplitude = u[r0]
        var tPeak: Int?, tEnd: Double?
        let tLo = clamp(jPoint + s(0.06))
        let tHi = clamp(min(r0 + s(0.45), r0 + s(0.7 * meanRRms / 1000)))
        if tLo < tHi, let peak = (tLo...tHi).max(by: { abs(u[$0]) < abs(u[$1]) }),
           abs(u[peak]) > 0.05 * rAmplitude {
            tPeak = peak
            let sign: Double = u[peak] > 0 ? 1 : -1
            let nextQRS = r0 + s(meanRRms / 1000 - 0.08)
            let descentHi = clamp(min(peak + s(0.2), nextQRS))
            if peak < descentHi, let steepest = (peak...descentHi).min(by: { sign * slope[$0] < sign * slope[$1] }),
               sign * slope[steepest] < 0 {
                let crossing = Double(steepest) - u[steepest] / slope[steepest]
                if crossing > Double(peak), crossing < Double(clamp(r0 + s(meanRRms / 1000 - 0.03))),
                   crossing <= Double(u.count - 1) { tEnd = crossing }
            }
        }

        // P wave: a positive bump before the QRS, measured only when it stands out.
        var pPeak: Int?, pOnset: Double?
        let pLo = clamp(r0 - s(min(0.30, 0.45 * meanRRms / 1000))), pHi = clamp(qrsOn - s(0.04))
        if pLo < pHi, let peak = (pLo...pHi).max(by: { u[$0] < u[$1] }), u[peak] > 0.03 * rAmplitude,
           peak > pLo {
            pPeak = peak
            let riseLo = clamp(peak - s(0.12))
            if riseLo < peak, let steepest = (riseLo..<peak).max(by: { slope[$0] < slope[$1] }), slope[steepest] > 0 {
                let crossing = Double(steepest) - u[steepest] / slope[steepest]
                if crossing < Double(peak), crossing >= Double(pLo) { pOnset = crossing }
            }
        }

        return Fiducials(pOnsetMs: pOnset.map(ms), pPeakMs: pPeak.map { ms(Double($0)) },
                         qrsOnsetMs: ms(Double(qrsOn)), jPointMs: ms(Double(jPoint)),
                         tPeakMs: tPeak.map { ms(Double($0)) }, tEndMs: tEnd.map(ms))
    }

    // MARK: - Helpers

    static func medianFilter(_ x: [Double], width: Int) -> [Double] {
        let half = width / 2
        return x.indices.map { k in median(Array(x[max(0, k - half)...min(x.count - 1, k + half)])) }
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
    }

    static func standardDeviation(_ values: [Double]) -> Double {
        let mean = values.reduce(0, +) / Double(values.count)
        return (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)).squareRoot()
    }

    static func columnMedian(_ rows: [[Double]]) -> [Double] {
        (0..<(rows.first?.count ?? 0)).map { c in median(rows.map { $0[c] }) }
    }

    static func pearson(_ a: [Double], _ b: [Double]) -> Double {
        let ma = a.reduce(0, +) / Double(a.count), mb = b.reduce(0, +) / Double(b.count)
        var num = 0.0, da = 0.0, db = 0.0
        for k in a.indices {
            num += (a[k] - ma) * (b[k] - mb)
            da += (a[k] - ma) * (a[k] - ma)
            db += (b[k] - mb) * (b[k] - mb)
        }
        return da > 0 && db > 0 ? num / (da * db).squareRoot() : 0
    }

    static func within(_ value: Double, _ range: ClosedRange<Double>) -> Double? {
        range.contains(value) ? value : nil
    }
}

/// Brings a strip recorded at another rate onto the 100 Hz grid `EcgAnalysis` measures on, so a
/// reference recording (an Apple Watch ECG at about 512 Hz) is measured by exactly the same code as the
/// strap's. A moving average one output period wide stops content above 50 Hz folding back into the
/// band, then each 10 ms point is read off by linear interpolation.
public enum EcgResample {
    public static func toHundredHertz(_ samples: [Double], rate: Double) -> [Int16?] {
        guard rate > 0, samples.count > 1 else { return [] }
        let width = max(1, Int((rate / 100).rounded()))
        var smoothed = samples
        if width > 1 {
            var prefix = [0.0]
            prefix.reserveCapacity(samples.count + 1)
            for value in samples { prefix.append(prefix[prefix.count - 1] + value) }
            let half = width / 2
            for k in samples.indices {
                let lo = max(0, k - half), hi = min(samples.count, k - half + width)
                smoothed[k] = (prefix[hi] - prefix[lo]) / Double(hi - lo)
            }
        }
        let count = Int(Double(samples.count - 1) / rate * 100) + 1
        return (0..<count).map { k -> Int16? in
            let position = Double(k) / 100 * rate
            let i = min(Int(position), smoothed.count - 2)
            let fraction = position - Double(i)
            let value = smoothed[i] + (smoothed[i + 1] - smoothed[i]) * fraction
            return Int16(clamping: Int(value.rounded()))
        }
    }
}
