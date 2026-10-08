import SwiftUI
import StrandDesign

// MARK: - WatchIntervalView — silent haptic HIIT, on the wrist
//
// The watch-native sibling of the phone's Interval Timer (Strand/Screens/IntervalTimerView.swift). Same
// model: a WORK / REST state machine over a number of rounds with the session total derived from
// work*rounds + rest*(rounds-1). The difference is where the buzz lands. On the phone the strap (or the
// phone's own Taptic engine) cues the transitions; here the watch IS on your wrist, so we fire WatchKit
// haptics through StrandHaptic at every WORK<->REST flip and round change. Train hands-free and let the
// wrist tell you when to switch, never looking at the face.
//
// Defaults match the phone: 30s work / 15s rest / 8 rounds. Scaled for the watch: one big countdown ring
// is the whole screen (flat track + solid phase-tinted arc) with the WORK/REST word, the SF-Rounded
// seconds and the round x/N inside it, and compact Start/Pause + Reset below. No config steppers up here
// on the small face — the wrist is for running the session, the phone owns setup.
struct WatchIntervalView: View {

    // Cross-lane contract: a no-arg init, fully self-contained.
    init() {}

    // MARK: Config (the phone's defaults — fixed on the watch, run-only surface)

    private let workSeconds = 30
    private let restSeconds = 15
    private let rounds = 8

    // MARK: Run state

    private enum Phase {
        case work, rest, done
        var label: String {
            switch self {
            case .work: return String(localized: "WORK")
            case .rest: return String(localized: "REST")
            case .done: return String(localized: "DONE")
            }
        }
    }

    @State private var phase: Phase = .work
    @State private var currentRound = 1
    @State private var remaining = 30      // whole seconds left in the current phase, as displayed
    @State private var running = false
    @State private var started = false     // anything has run since the last reset
    /// When the current phase ends while running. Remaining time is read off this deadline instead of
    /// counted down tick by tick, so a dimmed wrist or a late wake-up never stretches a phase.
    @State private var phaseEnd: Date?

    // MARK: Derived

    private var phaseDuration: Int {
        switch phase {
        case .work: return max(1, workSeconds)
        case .rest: return max(1, restSeconds)
        case .done: return 1
        }
    }

    /// 0...1 progress through the current interval.
    private var intervalProgress: Double {
        guard phaseDuration > 0 else { return 0 }
        let done = Double(phaseDuration - remaining)
        return min(1, max(0, done / Double(phaseDuration)))
    }

    /// The active phase's reset token: WORK uses the Effort colour, REST the Rest colour, DONE the
    /// positive green. Tints the flat ring arc, the phase word and the primary button (no glow).
    private var phaseColor: Color {
        switch phase {
        case .work: return StrandPalette.effortColor
        case .rest: return StrandPalette.restColor
        case .done: return StrandPalette.statusPositive
        }
    }

    private var isFinished: Bool { phase == .done }

    // MARK: Body

    var body: some View {
        // The countdown ring is the page: phase word, seconds and round all live inside it, the title sits
        // in the system bar, and one compact control row closes the face. The ring sizes itself to the
        // space the controls leave, so Start/Pause + Reset stay on screen from 40 mm up to an Ultra.
        VStack(spacing: 8) {
            heroRing
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            controls
        }
        .padding(.horizontal, 4)
        .task(id: running) {
            guard running else { return }
            while running, !Task.isCancelled {
                tick(now: Date())
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    // MARK: Hero ring — the countdown

    /// Flat phase-progress ring (visible track + solid reset-token arc, no glow) with the phase, the
    /// countdown and the round centred. Track and arc share one stroke so the arc sits on its track.
    private var heroRing: some View {
        GeometryReader { geo in
            let diameter = min(geo.size.width, geo.size.height)
            // Stroke scales with the ring so it stays proportional from a 40 mm right up to an Ultra.
            let lineWidth: CGFloat = max(7, min(11, diameter * 0.075))
            let fraction = isFinished ? 1 : intervalProgress
            ZStack {
                Circle()
                    .stroke(phaseColor.opacity(0.22), lineWidth: lineWidth)
                Circle()
                    .trim(from: 0, to: max(0.0001, CGFloat(fraction)))
                    .stroke(phaseColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.snappy, value: fraction)
                VStack(spacing: 0) {
                    Text(phase.label)
                        .font(StrandFont.overline)
                        .tracking(StrandFont.overlineTracking)
                        .foregroundStyle(phaseColor)
                    Text(isFinished ? "✓" : "\(remaining)")
                        .font(GlowRing.centerFont(diameter: diameter))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .monospacedDigit()
                        .contentTransition(.numericText(countsDown: true))
                    roundLabel
                }
                .lineLimit(1)
            }
            .frame(width: diameter, height: diameter)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(.snappy, value: remaining)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isFinished ? String(localized: "Session done")
                                        : String(localized: "\(remaining) seconds remaining in \(phase.label)"))
        .accessibilityValue(String(localized: "Round \(min(currentRound, rounds)) of \(rounds)"))
    }

    /// "n / N" under the countdown.
    private var roundLabel: some View {
        HStack(spacing: 2) {
            Text("\(min(currentRound, rounds))")
                .foregroundStyle(StrandPalette.textPrimary)
            Text("/ \(rounds)")
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .font(StrandFont.captionNumber)
    }

    // MARK: Controls — Start/Pause + Reset

    private var controls: some View {
        HStack(spacing: 8) {
            Button {
                if isFinished { resetToStart() }
                toggleRunning()
            } label: {
                Label(running ? String(localized: "Pause")
                              : (isFinished ? String(localized: "Restart") : String(localized: "Start")),
                      systemImage: running ? "pause.fill" : "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .tint(phaseColor)

            Button("Reset", systemImage: "arrow.counterclockwise", action: stopAndReset)
                .labelStyle(.iconOnly)
                .frame(width: 48)
                .tint(StrandPalette.surfaceRaised)
                .disabled(!started)
        }
        .buttonStyle(.borderedProminent)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Timer logic (reimplemented to match the phone's parameters)

    private func tick(now: Date) {
        guard running, !isFinished, let end = phaseEnd else { return }
        let left = max(0, Int(end.timeIntervalSince(now).rounded(.up)))
        // 3-2-1 countdown tick on the last seconds of the current phase — a light wrist tap.
        if left < remaining, remaining <= 3 {
            StrandHaptic.selection.play()
        }
        remaining = left
        if left == 0 { advancePhase(from: end) }
    }

    /// Move to the next phase. The next deadline is laid from the previous one, not from "now", so the
    /// session total stays exact however late this tick ran.
    private func advancePhase(from end: Date) {
        switch phase {
        case .work:
            if currentRound >= rounds {
                // Last work block finished → session complete.
                finishSession()
            } else {
                // Into rest — a soft single cue.
                phase = .rest
                remaining = max(1, restSeconds)
                phaseEnd = end.addingTimeInterval(TimeInterval(remaining))
                StrandHaptic.light.play()
            }
        case .rest:
            // Rest done → next round's work — a strong cue so you feel it without looking.
            currentRound += 1
            phase = .work
            remaining = max(1, workSeconds)
            phaseEnd = end.addingTimeInterval(TimeInterval(remaining))
            StrandHaptic.commit.play()
        case .done:
            break
        }
    }

    private func finishSession() {
        withAnimation(.snappy) {
            phase = .done
            remaining = 0
            running = false
            phaseEnd = nil
        }
        StrandHaptic.success.play()         // long completion cue
    }

    private func toggleRunning() {
        if isFinished { return }
        if running {
            // Freeze the displayed seconds; resuming lays a fresh deadline from them.
            running = false
            phaseEnd = nil
        } else {
            // Starting fresh from a clean reset → fire the opening WORK cue, like the phone does.
            if !started { StrandHaptic.commit.play() }
            started = true
            phaseEnd = Date().addingTimeInterval(TimeInterval(remaining))
            running = true
        }
    }

    private func stopAndReset() {
        running = false
        resetToStart()
    }

    /// Reset run state back to round 1 / start of work, using current config.
    private func resetToStart() {
        phase = .work
        currentRound = 1
        remaining = max(1, workSeconds)
        phaseEnd = nil
        started = false
    }
}

#if DEBUG
#Preview("Watch Interval") {
    WatchIntervalView()
}
#endif
