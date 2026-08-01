import SwiftUI
import StrandDesign

/// The live heart-rate readout leaf, shared by BOTH Today screens — `LiquidTodayView.heartRateSection`
/// and the classic `TodayView.heartRateTrendSection`. It lived inside LiquidTodayView.swift while Liquid
/// was its only caller; it is styled purely in `StrandPalette` / `StrandFont` tokens, so classic Today
/// hosts it unchanged rather than growing a second implementation of the same card (the Heute redesign's
/// `HeuteLiveHR` is a third copy only because it paints in its own `HeuteRedesignPalette`).
///
/// Owns LiveState so the ~1 Hz HR notifies re-render ONLY this card, never the whole Today (the isolation
/// both Today screens depend on). Keeps its own rolling buffer of live samples, shows the current bpm live
/// with a beat-by-beat trace, and falls back to the selected day's banked 5-minute trace when the strap
/// isn't streaming.
struct LiquidLiveHR: View {
    var tint: Color
    var fallback: [Double]        // today's banked 5-minute buckets — shown when there's no live stream
    var fallbackTimes: [Date]     // parallel to `fallback` — lets a scrub name the time it landed on
    var animated: Bool
    /// False on a navigated PAST day: the strap may well be streaming right now, but that number says
    /// nothing about the day on screen, so the card reads out the banked trace only and labels it as the
    /// selected day. (Defaults true — Liquid's own call site is unchanged by this.)
    var showsLive: Bool = true
    /// When set, the READOUT ROW (title / subtitle / bpm) becomes a link to this route — classic Today
    /// passes `.fullDayChart` so a tap on the live bpm opens the Deep Timeline. Only the row, never the
    /// whole card: the thread below owns a `minimumDistance: 2` scrub, and a card-wide link would swallow
    /// that drag as a tap (the same reason both Today screens keep "Full day" on its own footer control).
    var headerRoute: TabRoute? = nil
    /// Fires the moment the thread takes the touch and again when it lets go, so the host Today screen
    /// can suppress its day-swipe for the life of the scrub (see each screen's `daySwipeGesture`).
    var onScrubChange: (Bool) -> Void = { _ in }

    @EnvironmentObject private var live: LiveState
    @State private var samples: [Double] = []
    @State private var beat = false
    /// Which sample the finger is over (nil = not scrubbing). The OWNER of the gesture, per
    /// `LiquidThread`'s contract — the thread only draws the crosshair we resolve here.
    @State private var scrubIndex: Int?
    /// Measured width of the thread, needed to map a touch x back onto a sample index.
    @State private var threadWidth: CGFloat = 0
    private let maxSamples = 90   // ~1.5 min of 1 Hz live HR, enough to read the shape

    private var isLive: Bool { showsLive && live.connected && samples.count >= 2 }
    private var series: [Double] { isLive ? samples : fallback }
    /// The sample under the finger, if any — this is what the readout shows while scrubbing.
    private var scrubbedBpm: Int? {
        guard let i = scrubIndex, series.indices.contains(i) else { return nil }
        return Int(series[i].rounded())
    }
    private var bigBpm: Int? {
        if let scrubbed = scrubbedBpm { return scrubbed }
        if showsLive, let hr = live.heartRate, hr > 0, live.connected { return hr }
        if let last = fallback.last { return Int(last.rounded()) }
        return nil
    }
    private var subtitle: String {
        // While scrubbing the banked trace we can say exactly WHEN the sample is from; the live
        // beat-by-beat buffer carries no timestamps, so there it stays the plain live label.
        if let i = scrubIndex, !isLive, fallbackTimes.indices.contains(i) {
            return fallbackTimes[i].formatted(date: .omitted, time: .shortened)
        }
        if isLive { return String(localized: "Live · beat by beat") }
        if fallback.count >= 2 {
            // "since midnight" would be a today-shaped claim about a day that is over.
            return showsLive ? String(localized: "5-minute average · since midnight")
                             : String(localized: "5-minute average · selected day")
        }
        return live.connected && showsLive ? String(localized: "Waiting for the strap")
                                          : String(localized: "Strap not connected")
    }

    /// Scrub along the thread. `minimumDistance` is deliberately well under the day-swipe's 24pt so
    /// this recogniser engages FIRST and gets `onScrubChange(true)` written before the swipe could
    /// ever end — that ordering is what gives the thread horizontal dominance.
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
            if let headerRoute {
                NavigationLink(value: headerRoute) {
                    readout(showsChevron: true)
                        // The row spans the card width, so the whole readout strip is the hit target.
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the full-day heart rate timeline")
            } else {
                readout(showsChevron: false)
            }
            if series.count >= 2 {
                LiquidThread(bpm: series, tint: tint, height: 92, animated: animated,
                             scrubIndex: scrubIndex)
                    .background(GeometryReader { geo in
                        Color.clear
                            .onAppear { threadWidth = geo.size.width }
                            .onChangeCompat(of: geo.size.width) { threadWidth = $0 }
                    })
                    // The canvas paints only the curve, so without this the gaps between strokes
                    // would fall through to the scroll view and drop the scrub mid-drag.
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
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
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

    /// The title / subtitle / live-bpm row. Drawn identically whether or not it links onward; the chevron
    /// is the only difference, so the linked variant announces itself the way every other row-link does.
    private func readout(showsChevron: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("BEATS PER MINUTE").font(StrandFont.overline).tracking(1.6)
                    .foregroundStyle(StrandPalette.textSecondary)
                Text(subtitle).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
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
                (Text("\(hr)").font(StrandFont.rounded(22)).monospacedDigit()
                    + Text(" bpm").font(StrandFont.caption))
                    .foregroundStyle(tint)
                    .contentTransition(.numericText())
                    // No easing while scrubbing — a 0.25s ramp per sample would visibly trail
                    // the finger instead of reading out the value under it.
                    .animation(scrubIndex == nil ? .easeOut(duration: 0.25) : nil, value: hr)
            }
            if showsChevron {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(StrandPalette.accent)
            }
        }
    }

    private func stat(_ label: String, _ v: Double?) -> some View {
        HStack(spacing: 5) {
            Text(label).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            Text(v.map { String(Int($0.rounded())) } ?? "–")
                .font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textSecondary)
        }
    }
}
