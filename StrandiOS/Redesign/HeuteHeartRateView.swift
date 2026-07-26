import SwiftUI
import StrandDesign

// MARK: - Heute heart-rate section (parity with LiquidTodayView.heartRateSection)
//
// The Heute redesign was the only Today screen with NO heart-rate section — Liquid and classic both show
// live HR plus a scrubbable day trace. This adds it in Heute's own token set. The drawing primitive
// `LiquidThread` (Strand/Liquid/LiquidPrimitives.swift) is REUSED as-is — it is palette-neutral (takes a
// `tint`) and already designed for owner-driven scrubbing (it draws the crosshair for a `scrubIndex` the
// owner resolves). Only the surrounding view is rebuilt here because `LiquidLiveHR` is private and
// StrandPalette/StrandFont-styled; the scrub + day-swipe-suppression logic is a faithful port of the P4
// Liquid implementation.

/// A "Heart rate" section: an overline title over a tile card with the live-BPM read-out, a scrubbable
/// 5-minute trace, and Min/Avg/Max. Shown on any selected day (a past day scrubs its banked trace; only
/// the live beat-by-beat layer is inactive then).
struct HeuteHeartRateSection: View {
    /// The selected day's banked 5-minute buckets and their start times, index-aligned (from
    /// `HeuteRedesignView.hrValues`/`hrTimes`). The live stream is layered on top of these when connected.
    let values: [Double]
    let times: [Date]
    var animated: Bool
    /// Fires true when the thread takes a scrub touch and false on release, so the host can suppress its
    /// day-swipe for the life of the scrub (see `HeuteRedesignView.daySwipeGesture`).
    var onScrubChange: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Heart rate")
                .font(.system(size: 10, weight: .bold))
                .tracking(1.1)
                .textCase(.uppercase)
                .foregroundStyle(HeuteRedesignPalette.ink3)
            HeuteLiveHR(tint: HeuteRedesignPalette.heart, fallback: values, fallbackTimes: times,
                        animated: animated, onScrubChange: onScrubChange)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(HeuteRedesignPalette.tile, in: RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(HeuteRedesignPalette.line, lineWidth: 1))
        }
    }
}

/// The live-HR card content, Heute-styled. A faithful port of `LiquidLiveHR` (Strand/Liquid/
/// LiquidTodayView.swift): a live beat-by-beat buffer layered over the banked `fallback` trace, a
/// finger-follows-value scrub, and a Min/Avg/Max footer.
private struct HeuteLiveHR: View {
    var tint: Color
    var fallback: [Double]        // the selected day's banked 5-minute buckets
    var fallbackTimes: [Date]     // parallel to `fallback` — lets a scrub name the time it landed on
    var animated: Bool
    var onScrubChange: (Bool) -> Void = { _ in }

    @EnvironmentObject private var live: LiveState
    @State private var samples: [Double] = []
    @State private var beat = false
    /// Which sample the finger is over (nil = not scrubbing). The OWNER of the gesture, per
    /// `LiquidThread`'s contract — the thread only draws the crosshair we resolve here.
    @State private var scrubIndex: Int?
    /// Measured thread width, to map a touch x back onto a sample index.
    @State private var threadWidth: CGFloat = 0
    private let maxSamples = 90   // ~1.5 min of 1 Hz live HR, enough to read the shape

    private var isLive: Bool { live.connected && samples.count >= 2 }
    private var series: [Double] { isLive ? samples : fallback }
    /// The sample under the finger, if any — what the read-out shows while scrubbing.
    private var scrubbedBpm: Int? {
        guard let i = scrubIndex, series.indices.contains(i) else { return nil }
        return Int(series[i].rounded())
    }
    private var bigBpm: Int? {
        if let scrubbed = scrubbedBpm { return scrubbed }
        if let hr = live.heartRate, hr > 0, live.connected { return hr }
        if let last = fallback.last { return Int(last.rounded()) }
        return nil
    }
    private var subtitle: String {
        // Scrubbing the banked trace, we can say exactly WHEN the sample is from; the live beat-by-beat
        // buffer carries no timestamps, so there it stays the plain live label.
        if let i = scrubIndex, !isLive, fallbackTimes.indices.contains(i) {
            return fallbackTimes[i].formatted(date: .omitted, time: .shortened)
        }
        if isLive { return String(localized: "Live · beat by beat") }
        if fallback.count >= 2 { return String(localized: "5-minute average · since midnight") }
        return live.connected ? String(localized: "Waiting for the strap") : String(localized: "Strap not connected")
    }

    /// Scrub along the thread. `minimumDistance` is deliberately well under the day-swipe's 24pt so this
    /// recogniser engages FIRST and writes `onScrubChange(true)` before the swipe could ever end — that
    /// ordering is what gives the thread horizontal dominance.
    private var scrubGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard series.count >= 2, threadWidth > 0 else { return }
                if scrubIndex == nil { onScrubChange(true) }
                let frac = min(max(0, value.location.x / threadWidth), 1)
                scrubIndex = Int((frac * CGFloat(series.count - 1)).rounded())
            }
            .onEnded { _ in
                guard scrubIndex != nil else { return }
                scrubIndex = nil
                onScrubChange(false)
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("BEATS PER MINUTE")
                        .font(.system(size: 11, weight: .bold)).tracking(1.6)
                        .foregroundStyle(HeuteRedesignPalette.ink2)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(HeuteRedesignPalette.ink3)
                }
                Spacer()
                if isLive {
                    // A gentle heartbeat dot that pulses with each incoming sample.
                    Circle().fill(tint).frame(width: 7, height: 7)
                        .scaleEffect(beat ? 1.35 : 0.85)
                        .opacity(beat ? 1 : 0.45)
                        .animation(.easeOut(duration: 0.28), value: beat)
                        .padding(.trailing, 2)
                }
                if let hr = bigBpm {
                    (Text("\(hr)").font(.system(size: 22, weight: .bold, design: .rounded)).monospacedDigit()
                        + Text(" bpm").font(.system(size: 12)))
                        .foregroundStyle(tint)
                        .contentTransition(.numericText())
                        // No easing while scrubbing — a 0.25s ramp per sample would visibly trail the
                        // finger instead of reading out the value under it.
                        .animation(scrubIndex == nil ? .easeOut(duration: 0.25) : nil, value: hr)
                }
            }
            if series.count >= 2 {
                LiquidThread(bpm: series, tint: tint, height: 92, animated: animated, scrubIndex: scrubIndex)
                    .background(GeometryReader { geo in
                        Color.clear
                            .onAppear { threadWidth = geo.size.width }
                            .onChangeCompat(of: geo.size.width) { threadWidth = $0 }
                    })
                    // The canvas paints only the curve, so without this the gaps between strokes would
                    // fall through to the scroll view and drop the scrub mid-drag.
                    .contentShape(Rectangle())
                    .gesture(scrubGesture)
                HStack {
                    stat(String(localized: "Min"), series.min())
                    Spacer()
                    stat(String(localized: "Avg"), series.reduce(0, +) / Double(series.count))
                    Spacer()
                    stat(String(localized: "Max"), series.max())
                }
            } else {
                Text(live.connected ? "Waiting for a live heartbeat…" : "Connect your strap to see live heart rate")
                    .font(.system(size: 12))
                    .foregroundStyle(HeuteRedesignPalette.ink3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 24)
            }
        }
        .onAppear { if samples.isEmpty, let hr = live.heartRate, hr > 0 { samples = [Double(hr)] } }
        .onChangeCompat(of: live.heartRate) { hr in
            guard let hr, hr > 0 else { return }
            samples.append(Double(hr))
            if samples.count > maxSamples { samples.removeFirst(samples.count - maxSamples) }
            beat.toggle()
        }
    }

    private func stat(_ label: String, _ v: Double?) -> some View {
        HStack(spacing: 5) {
            Text(label).font(.system(size: 12)).foregroundStyle(HeuteRedesignPalette.ink3)
            Text(v.map { String(Int($0.rounded())) } ?? "–")
                .font(.system(size: 12, weight: .medium)).monospacedDigit()
                .foregroundStyle(HeuteRedesignPalette.ink2)
        }
    }
}
