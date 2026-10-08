import SwiftUI
import Foundation
import StrandDesign
import StrandAnalytics

// MARK: - WatchBreatheView — wrist-native catalog-driven breathing
//
// Reimplements the phone Breathe trainer on-watch: [BreathProtocolCatalog.watchSubset] protocols,
// stage-accurate inhale/hold/exhale pacing, session length Open/5/10/15 with auto-stop, and Taptic cues
// (one tap inhale, double exhale; holds silent). Pattern and length are chosen in an Options sheet so the
// page itself stays a ring and a button. Zero-arg init; the page deck wires it by name.

struct WatchBreatheView: View {

    private enum SessionLength: Hashable, CaseIterable {
        case open, five, ten, fifteen

        var label: String {
            switch self {
            case .open: return String(localized: "Open")
            case .five: return String(localized: "5m")
            case .ten: return String(localized: "10m")
            case .fifteen: return String(localized: "15m")
            }
        }

        var targetSeconds: Int? {
            switch self {
            case .open: return nil
            case .five: return 5 * 60
            case .ten: return 10 * 60
            case .fifteen: return 15 * 60
            }
        }

        static func from(recommendedMs: Int) -> SessionLength {
            switch recommendedMs {
            case ..<(7 * 60_000): return .five
            case ..<(12 * 60_000): return .ten
            default: return .fifteen
            }
        }
    }

    private enum Phase { case inhale, hold, exhale, textOnly }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var protocolId: String = "coherence_5_5"
    @State private var sessionLength: SessionLength = .ten
    @State private var running = false

    @State private var ringProgress: CGFloat = 0
    /// The curve for the next ring change. Applied to the orb alone so a 5 s inhale never drags the
    /// text changes made in the same update along with it.
    @State private var ringAnimation: Animation?
    @State private var phase: Phase = .inhale
    @State private var phaseLabel: String? = nil
    @State private var stageIndex: Int = 0
    @State private var phaseDeadline: Date = .distantFuture
    @State private var phaseStart: Date = Date()
    @State private var phaseRemaining: Int = 0

    @State private var breathCount = 0
    @State private var sessionSeconds = 0
    @State private var sessionStart = Date()
    @State private var showingOptions = false

    private let reducedSteadyRing: CGFloat = 0.5

    private var protocols: [BreathProtocol] { BreathProtocolCatalog.watchSubset }

    private var selectedProtocol: BreathProtocol? {
        BreathProtocolCatalog.protocolById(protocolId)
    }

    private var isGuided: Bool { selectedProtocol?.mode == .guided }

    private var selectedBpm: Double {
        guard let proto = selectedProtocol, proto.cycleDurationMs > 0 else { return 0 }
        return 60_000.0 / Double(proto.cycleDurationMs)
    }

    var body: some View {
        // The face holds only what a session needs: the breathing ring, one status line and Start/Stop.
        // The pattern and the length live in an Options sheet behind the toolbar button, so the ring gets
        // the screen instead of sharing it with two rows of pills.
        // Start/Stop sits in the system bottom bar, so the ring keeps the height a full-width button
        // would take. The bar floats over the bottom edge, so the ring stops short of it and the status
        // line sits above the ring, under the title.
        VStack(spacing: 4) {
            statusLine
            ring
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 16)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Options", systemImage: "slider.horizontal.3") { showingOptions = true }
                    .disabled(running)
            }
            ToolbarItemGroup(placement: .bottomBar) {
                Spacer()
                control
                Spacer()
            }
        }
        .sheet(isPresented: $showingOptions) { optionsSheet }
        // One loop drives the whole session and only exists while a session runs (task(id:) cancels it
        // on Stop). Times are read off the clock rather than counted, so a dimmed wrist or a late wake-up
        // never stretches the session or a phase.
        .task(id: running) {
            guard running else { return }
            while running, !Task.isCancelled {
                let now = Date()
                advance(now: now)
                updateCountdown(now: now)
                sessionSeconds = Int(now.timeIntervalSince(sessionStart))
                if let target = sessionLength.targetSeconds, sessionSeconds >= target {
                    stop()
                    break
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        .onChange(of: protocolId) { _, newId in
            if running { stop() }
            if let proto = BreathProtocolCatalog.protocolById(newId) {
                sessionLength = SessionLength.from(recommendedMs: proto.recommendedDurationMs)
            }
        }
        .onDisappear { stop() }
    }

    // MARK: - Ring

    private var ring: some View {
        GeometryReader { geo in
            let maxDiameter = min(geo.size.width, geo.size.height)
            let minScale: CGFloat = 0.46
            let guideDiameter = maxDiameter * (minScale + (1.0 - minScale) * ringProgress)

            ZStack {
                Circle()
                    .strokeBorder(StrandPalette.restColor.opacity(0.26), lineWidth: 1)
                    .frame(width: maxDiameter, height: maxDiameter)

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [StrandPalette.restBright.opacity(0.85),
                                     StrandPalette.restColor.opacity(0.55),
                                     StrandPalette.restDeep.opacity(0.80)],
                            center: .init(x: 0.4, y: 0.35),
                            startRadius: 1,
                            endRadius: guideDiameter * 0.62
                        )
                    )
                    .frame(width: guideDiameter, height: guideDiameter)
                    .animation(ringAnimation, value: ringProgress)

                Circle()
                    .strokeBorder(StrandPalette.restBright.opacity(running ? 0.70 : 0.40), lineWidth: 2)
                    .frame(width: guideDiameter, height: guideDiameter)
                    .animation(ringAnimation, value: ringProgress)

                // The page width, not the ring's: a long localized pace unit may graze the hairline track
                // rather than truncate.
                centerLabel
                    .frame(maxWidth: geo.size.width)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    @ViewBuilder
    private var centerLabel: some View {
        VStack(spacing: 2) {
            if running {
                Text(phaseWord)
                    .font(StrandFont.rounded(15, weight: .semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .multilineTextAlignment(.center)
                    .animation(.easeInOut(duration: 0.2), value: phase)
                if !isGuided {
                    Text("\(max(phaseRemaining, 0))")
                        .font(StrandFont.number(28))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
            } else {
                // The pattern's name and length are on the status line below; the centre carries the pace.
                Text(idleDetail)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .multilineTextAlignment(.center)
            }
        }
        .lineLimit(2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(running ? phaseAccessibilityLabel : String(localized: "Ready to breathe"))
    }

    /// The idle centre's second line: the pace for a timed pattern, "Guided" for a cue-driven one.
    private var idleDetail: String {
        if isGuided { return String(localized: "Guided") }
        guard selectedBpm > 0 else { return sessionLength.label }
        let bpm = selectedBpm.formatted(.number.precision(.fractionLength(1)))
        return String(format: String(localized: "%@ br/min"), bpm)
    }

    private var phaseWord: String {
        if let phaseLabel, !phaseLabel.isEmpty {
            return phaseLabel
        }
        switch phase {
        case .inhale: return String(localized: "Breathe in")
        case .hold: return String(localized: "Hold")
        case .exhale: return String(localized: "Breathe out")
        case .textOnly: return String(localized: "Follow cue")
        }
    }

    private var phaseAccessibilityLabel: String {
        let secs = max(phaseRemaining, 0)
        switch phase {
        case .inhale: return String(localized: "Breathe in for \(secs) seconds")
        case .hold: return String(localized: "Hold for \(secs) seconds")
        case .exhale: return String(localized: "Breathe out for \(secs) seconds")
        case .textOnly: return String(localized: "Follow the guided cue")
        }
    }

    // MARK: - Status line

    /// Idle: the chosen pattern and length. Running: breaths and time against the target.
    private var statusLine: some View {
        Text(running ? sessionReadout : idlePaceLine)
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textSecondary)
            .monospacedDigit()
            .lineLimit(1)
            .frame(maxWidth: .infinity)
    }

    private var sessionReadout: String {
        if let target = sessionLength.targetSeconds {
            return String(localized: "\(breathCount) breaths · \(timeString(sessionSeconds))/\(timeString(target))")
        }
        return String(localized: "\(breathCount) breaths · \(timeString(sessionSeconds))")
    }

    private var idlePaceLine: String {
        let title = selectedProtocol.map { watchLabel(for: $0) } ?? protocolId
        if isGuided {
            return String(localized: "\(title) · guided")
        }
        return String(localized: "\(title) · \(sessionLength.label)")
    }

    // MARK: - Options

    /// Pattern and length as two inline pickers, the standard watch list with a checkmark on the choice.
    private var optionsSheet: some View {
        NavigationStack {
            List {
                Picker("Pattern", selection: $protocolId) {
                    ForEach(protocols, id: \.id) { proto in
                        Text(watchLabel(for: proto)).tag(proto.id)
                    }
                }
                .pickerStyle(.inline)

                Picker("Length", selection: $sessionLength) {
                    ForEach(SessionLength.allCases, id: \.self) { length in
                        Text(length.label).tag(length)
                    }
                }
                .pickerStyle(.inline)
            }
            .navigationTitle("Options")
        }
        .onChange(of: protocolId) { StrandHaptic.selection.play() }
        .onChange(of: sessionLength) { StrandHaptic.selection.play() }
    }

    private func watchLabel(for proto: BreathProtocol) -> String {
        switch proto.id {
        case "relax_4_6": return String(localized: "Relax")
        case "coherence_5_5": return String(localized: "Coherence")
        case "box_4_4_4_4": return String(localized: "Box")
        case "deep_4_2_6": return String(localized: "Deep")
        case "four_seven_eight": return String(localized: "4-7-8")
        case "coherent_6_6": return String(localized: "6-6")
        case "presence_regular": return String(localized: "Regular")
        case "presence_mid": return String(localized: "Mid")
        case "presence_punching": return String(localized: "Push")
        default:
            return String(proto.title.split(separator: " ").first ?? Substring(proto.title))
        }
    }

    // MARK: - Control

    private var control: some View {
        // Icon-only in the bottom bar; the label still carries the word for VoiceOver.
        Button {
            running ? stop() : start()
        } label: {
            Label(running ? String(localized: "Stop") : String(localized: "Start"),
                  systemImage: running ? "stop.fill" : "play.fill")
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderedProminent)
        .tint(running ? StrandPalette.statusCritical : StrandPalette.restColor)
        .accessibilityLabel(running ? String(localized: "Stop session") : String(localized: "Start session"))
    }

    // MARK: - Session engine

    private func currentStages() -> [BreathStage] {
        selectedProtocol?.stages.filter { $0.durationMs > 0 } ?? []
    }

    private func start() {
        running = true
        sessionStart = Date()
        sessionSeconds = 0
        breathCount = 0
        stageIndex = 0
        phaseLabel = nil
        StrandHaptic.success.play()
        if isGuided {
            phase = .textOnly
            phaseLabel = selectedProtocol?.title
            phaseDeadline = .distantFuture
            ringAnimation = nil
            ringProgress = reducedSteadyRing
        } else {
            armCurrentStage(from: Date(), buzz: true)
        }
    }

    private func stop() {
        guard running else { return }
        running = false
        phaseDeadline = .distantFuture
        phaseLabel = nil
        StrandHaptic.commit.play()
        ringAnimation = reduceMotion ? nil : .easeInOut(duration: 0.7)
        ringProgress = 0
    }

    private func armCurrentStage(from now: Date, buzz: Bool) {
        let stages = currentStages()
        guard !stages.isEmpty else { return }
        let stage = stages[stageIndex % stages.count]
        switch stage.type {
        case .inhale: phase = .inhale
        case .hold: phase = .hold
        case .exhale: phase = .exhale
        case .textOnly: phase = .textOnly
        }
        phaseLabel = stage.label
        let duration = Double(stage.durationMs) / 1000.0
        phaseStart = now
        phaseDeadline = now.addingTimeInterval(duration)
        phaseRemaining = Int(duration.rounded(.up))

        if reduceMotion {
            ringAnimation = nil
            ringProgress = reducedSteadyRing
        } else {
            ringAnimation = .easeInOut(duration: duration)
            switch phase {
            case .inhale: ringProgress = 1.0
            case .exhale: ringProgress = 0.0
            case .hold, .textOnly: break
            }
        }

        if buzz {
            let loops = BreathProtocolPlayer.loops(for: stage.type)
            if loops > 0 {
                StrandHaptic.light.play()
                if loops >= 2 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                        StrandHaptic.light.play()
                    }
                }
            }
        }
    }

    private func advance(now: Date) {
        guard !isGuided else { return }
        guard now >= phaseDeadline else { return }
        let stages = currentStages()
        guard !stages.isEmpty else { return }
        let completed = stages[stageIndex % stages.count]
        stageIndex += 1
        if completed.type == .exhale { breathCount += 1 }
        armCurrentStage(from: now, buzz: true)
    }

    private func updateCountdown(now: Date) {
        let left = phaseDeadline.timeIntervalSince(now)
        phaseRemaining = max(0, Int(left.rounded(.up)))
    }

    private func timeString(_ total: Int) -> String {
        String(format: "%d:%02d", total / 60, total % 60)
    }
}
