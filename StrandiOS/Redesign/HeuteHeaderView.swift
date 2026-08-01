import SwiftUI
import StrandDesign

// MARK: - Kopfzeile (docs/fork/feature-spec.md §1, §5; docs/fork/design/design-spec.md §1)
//
// Greeting + date on the left, three 30×30pt chips on the right: activity-status (tap once to expand
// and reveal the label + a warning ring for the three exception states, tap again to open the status
// sheet), strap battery, coach entry. The status chip is the novel/complex piece here; battery and
// coach reuse existing app state rather than inventing new logic (see each chip's doc comment).

struct HeuteHeaderView: View {
    @EnvironmentObject private var profile: ProfileStore
    @EnvironmentObject private var coach: AICoachEngine
    @AppStorage(CoachFeaturePrefs.enabledKey) private var coachFeatureEnabled = false
    /// Shared with the host's Basiskarte (`HeuteCardZoneView`) — both must read the SAME status, or
    /// changing it in the sheet wouldn't be reflected in the base card. Owned by the screen root.
    @Binding var status: ActivityStatus
    /// Days back from today (0 = today), shared with the host so the whole screen's data reloads for
    /// the selected day — not covered by feature-spec/design-spec at all, added from on-device feedback
    /// ("keine Tagewechsel-Funktion"). Tapping the date line reveals `DayNavBar` (StrandDesign, already
    /// built for exactly this on the classic Today screen) rather than a new control.
    @Binding var selectedDayOffset: Int
    /// The oldest reachable offset (whole days back to the earliest banked day), computed by the host.
    /// `DayNavBar`'s "older" chevron is otherwise unbounded — it would step past the earliest data day
    /// onto empty days — so the selection is clamped to `0 ... earliestDayOffset` here, mirroring the
    /// day-swipe on the host and the classic Today's chevron bounds.
    var earliestDayOffset: Int = 0
    /// The host owns `.coachCover`'s presentation (same idiom as `CoachTodayRow`/`CoachFloatingButton` —
    /// the chip only flips this true, it never presents the chat itself).
    @State private var showCoach = false
    @State private var showDayNav = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(greetingLine)
                        .font(StrandFont.title2)
                        .foregroundStyle(HeuteRedesignPalette.ink)
                    Button {
                        withAnimation(StrandMotion.interactive) { showDayNav.toggle() }
                    } label: {
                        Text(dateLine)
                            .font(StrandFont.caption)
                            .foregroundStyle(HeuteRedesignPalette.ink3)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Change day"))
                }
                Spacer(minLength: 8)
                HStack(spacing: 8) {
                    ActivityStatusChip(status: $status)
                    HeuteBatteryChip()
                    if coachFeatureEnabled {
                        HeuteCoachChip(isPresented: $showCoach)
                    }
                }
            }
            if showDayNav {
                // Anchored to the LOGICAL day, exactly like `TodayView`'s own `DayNavBar` — with a raw
                // `Date()` anchor the 00:00–04:00 window labelled offset 0 and 1 as the same date.
                DayNavBar(selectedOffset: selectedDayOffset, today: Repository.logicalDay(Date())) { newOffset in
                    // Clamp to real data: the "older" chevron is unbounded in DayNavBar, so without this a
                    // tap could strand the screen on a day with nothing banked. Same bound as the host's swipe.
                    selectedDayOffset = min(max(0, newOffset), earliestDayOffset)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .coachCover(isPresented: $showCoach, coach: coach)
    }

    private var greetingLine: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let greeting = hour < 12 ? String(localized: "Good morning")
            : hour < 17 ? String(localized: "Good afternoon")
            : String(localized: "Good evening")
        guard let name = profile.displayName else { return greeting }
        return "\(greeting), \(name)"
    }

    /// The line that opens day-nav; reflects whichever day is currently selected, not always "today"
    /// — so after navigating back, this row itself shows where you are. Always the full weekday+date
    /// ("Friday, July 24"), matching design-spec §1's own worked example — a literal "Today"/"Yesterday"
    /// label was an implementation drift from that spec, not an intentional alternative (on-device
    /// feedback flagged it as feeling unnatural).
    private var dateLine: String {
        let base = Repository.logicalDay(Date())
        let date = Calendar.current.date(byAdding: .day, value: -selectedDayOffset, to: base) ?? base
        return date.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }
}

// MARK: - Status chip

/// One tap opens the status sheet directly (on-device feedback: the mockup's original two-stage "tap to
/// reveal the label, tap again to open the sheet" read as needing two taps to do one thing — deliberately
/// diverges from `docs/fork/design/mockup-heute.html` `.statuschip` here). `expanded` still drives the
/// 30pt-disc → 118pt-capsule widen + label reveal + warning-colour ring, now set alongside `showSheet`
/// rather than gating it, so the chip still widens (matching the mockup's visual) at the same moment the
/// sheet comes up, and collapses back on dismiss.
struct ActivityStatusChip: View {
    @Binding var status: ActivityStatus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false
    @State private var showSheet = false

    private let restingSize: CGFloat = 30
    private let expandedWidth: CGFloat = 118

    var body: some View {
        Button(action: handleTap) {
            HStack(spacing: 6) {
                Image(systemName: status.state.symbolName)
                    .font(.system(size: 14))
                    .foregroundStyle(HeuteRedesignPalette.ink2)
                    .frame(width: 14, height: 14)
                if expanded {
                    Text(status.state.displayName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(HeuteRedesignPalette.ink)
                        .lineLimit(1)
                        .fixedSize()
                        .transition(.opacity)
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, expanded ? 12 : 0)
            .frame(width: expanded ? expandedWidth : restingSize, height: restingSize, alignment: .leading)
            .background(HeuteRedesignPalette.tile, in: Capsule())
            // Base border every chip has at rest (design-spec §1: "identisch zu Akku- und Coach-Chip") —
            // was missing, which made the .active chip look bare next to its siblings. The warning ring
            // is a SEPARATE layer on top, only for the expanded exception states.
            .overlay(Capsule().strokeBorder(HeuteRedesignPalette.line, lineWidth: 1))
            .overlay(Capsule().strokeBorder(ringColor, lineWidth: 1.5).padding(-1))
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: expanded)
        // Collapse back to the 30pt disc once the sheet closes — otherwise the chip stayed expanded and
        // the very next tap re-opened the sheet instead of reading as "expand" (the mockup's outside-tap
        // collapse doesn't exist here, see the note above).
        .sheet(isPresented: $showSheet, onDismiss: { expanded = false }) {
            ActivityStatusSheet(status: $status)
                .noopSheetPresentation(largeFirst: false)
        }
        .accessibilityLabel(Text("Activity status: \(status.state.displayName)"))
        .accessibilityHint(Text("Double tap to change"))
    }

    private var ringColor: Color {
        expanded && status.state != .active ? HeuteRedesignPalette.attn : .clear
    }

    private func handleTap() {
        expanded = true
        showSheet = true
    }
}

/// The Aktivitätsstatus bottom sheet: four state rows (icon + title + subtitle + radio) then a duration
/// pill row mapping 1:1 onto `ActivityStatus.Duration`, an optional date picker, and "Apply".
/// docs/fork/design/mockup-heute.html `#sheet`.
struct ActivityStatusSheet: View {
    @Binding var status: ActivityStatus
    @Environment(\.dismiss) private var dismiss

    @State private var pendingState: ActivityStatus.State
    @State private var pendingDuration: DurationChoice = .untilChanged
    @State private var customDate = Date()

    init(status: Binding<ActivityStatus>) {
        _status = status
        _pendingState = State(initialValue: status.wrappedValue.state)
    }

    enum DurationChoice: CaseIterable {
        case untilChanged, today, threeDays, thisWeek, custom

        var label: String {
            switch self {
            case .untilChanged: return String(localized: "Until changed")
            case .today:        return String(localized: "Today")
            case .threeDays:    return String(localized: "3 days")
            case .thisWeek:     return String(localized: "This week")
            case .custom:       return String(localized: "Custom date")
            }
        }

        var duration: ActivityStatus.Duration {
            switch self {
            case .untilChanged: return .untilChanged
            case .today:        return .today
            case .threeDays:    return .threeDays
            case .thisWeek:     return .thisWeek
            case .custom:       return .custom(Date())   // overridden with customDate at apply time
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 4) {
                Text("Activity status")
                    .font(StrandFont.headline)
                    .padding(.bottom, 12)

                ForEach(ActivityStatus.State.allCases, id: \.self) { state in
                    stateRow(state)
                }

                durationSection

                Button(action: apply) {
                    Text("Apply")
                        .font(.system(size: 15, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .foregroundStyle(HeuteRedesignPalette.sheet)
                        .background(HeuteRedesignPalette.ink, in: RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
                .padding(.top, 18)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
        }
        .background(HeuteRedesignPalette.sheet)
    }

    private func stateRow(_ state: ActivityStatus.State) -> some View {
        let selected = pendingState == state
        return Button { pendingState = state } label: {
            HStack(spacing: 12) {
                Image(systemName: state.symbolName)
                    .foregroundStyle(HeuteRedesignPalette.ink)
                    .frame(width: 36, height: 36)
                    .background(HeuteRedesignPalette.tile2, in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.displayName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(HeuteRedesignPalette.ink)
                    Text(state.subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(HeuteRedesignPalette.ink3)
                }
                Spacer()
                Circle()
                    .strokeBorder(selected ? radioColor(state) : HeuteRedesignPalette.ink3, lineWidth: 1.6)
                    .frame(width: 19, height: 19)
                    .overlay {
                        if selected {
                            Circle().fill(radioColor(state)).padding(3)
                        }
                    }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func radioColor(_ state: ActivityStatus.State) -> Color {
        state == .active ? HeuteRedesignPalette.charge : HeuteRedesignPalette.attn
    }

    private var durationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Valid for")
                .font(.system(size: 11, weight: .bold))
                .tracking(0.9)
                .textCase(.uppercase)
                .foregroundStyle(HeuteRedesignPalette.ink3)
                .padding(.horizontal, 8)

            FlowRow(spacing: 8) {
                ForEach(DurationChoice.allCases, id: \.self) { choice in
                    Button(choice.label) { pendingDuration = choice }
                        .buttonStyle(DurationPillStyle(selected: pendingDuration == choice))
                }
            }
            .padding(.horizontal, 8)

            if pendingDuration == .custom {
                DatePicker("", selection: $customDate, displayedComponents: .date)
                    .datePickerStyle(.compact)
                    .labelsHidden()
                    .padding(.horizontal, 8)
                    .padding(.top, 2)
            }
        }
        .padding(.top, 14)
        .overlay(alignment: .top) { Rectangle().fill(HeuteRedesignPalette.line).frame(height: 1) }
    }

    private func apply() {
        let now = Date()
        let duration: ActivityStatus.Duration = pendingDuration == .custom ? .custom(customDate) : pendingDuration.duration
        status = ActivityStatus(state: pendingState, validUntil: duration.validUntil(from: now), setAt: now)
        ActivityStatusStore.save(status)
        dismiss()
    }
}

private struct DurationPillStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .foregroundStyle(selected ? HeuteRedesignPalette.ink : HeuteRedesignPalette.ink2)
            .background(selected ? HeuteRedesignPalette.tile2 : HeuteRedesignPalette.tile, in: Capsule())
            .overlay(Capsule().strokeBorder(HeuteRedesignPalette.line, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// A minimal wrapping row (SwiftUI has no built-in wrap HStack pre-iOS 26 `Layout` conveniences here) —
/// the duration row only ever has 5 short pills, so a simple wrap is enough; no need for the general
/// `FlowLayout` in `Strand/Liquid/LiquidPrimitives.swift` (chip-cloud layout, different call shape).
private struct FlowRow<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content
    var body: some View {
        // Two rows of pills reads fine at the sheet's width for 5 items; a true reflow isn't worth the
        // complexity for a fixed, short list.
        HStack(spacing: spacing) {
            content()
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Battery chip

/// Icon-only strap-battery chip (design-spec §1: "Icon-only, kein Zahlenwert nötig im Ruhezustand").
/// Reads the SAME state `LiquidBatteryButton` (Strand/Liquid/LiquidTodayView.swift) reads — that type is
/// `private` to its file so it can't be reused directly, but `LiveState`/`NavRouter` are the real shared
/// state, not new logic.
struct HeuteBatteryChip: View {
    @EnvironmentObject private var live: LiveState
    @EnvironmentObject private var router: NavRouter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var blinkOn = true

    var body: some View {
        Button { router.openDevices() } label: {
            Group {
                if let displayPct {
                    // SF Symbols' native "Variable Value" rendering (iOS 16+, the same mechanism Apple's
                    // own status bar uses for battery) — one symbol, continuously filled, instead of the
                    // 5 discrete battery.0/25/50/75/100 steps this used before (on-device feedback: the
                    // fill has to visibly track the real level, not jump between fixed icons).
                    Image(systemName: "battery.100", variableValue: displayPct)
                } else {
                    Image(systemName: fallbackSymbolName)
                }
            }
            .font(.system(size: 14))
            .foregroundStyle(tint)
            .opacity(isCritical && blinkOn ? 0.35 : 1)
            .frame(width: 30, height: 30)
            .background(HeuteRedesignPalette.tile, in: Capsule())
            .overlay(Capsule().strokeBorder(HeuteRedesignPalette.line, lineWidth: 1))
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: displayPct)
        .buttonStyle(.plain)
        .accessibilityLabel(Text(accessibilityText))
        .onAppear { startBlinkIfNeeded() }
        .onChange(of: isCritical) { _, _ in startBlinkIfNeeded() }
    }

    /// nil when there's no real reading to fill against (offline / pending) — the fallback icon covers
    /// those. A small floor (2%) keeps the symbol from rendering fully hollow at a genuine near-zero
    /// reading, matching how Apple's own battery UI never shows a completely empty outline.
    private var displayPct: Double? {
        guard live.connected, let pct = live.batteryPct else { return nil }
        return max(0.02, min(1, pct / 100))
    }

    private var fallbackSymbolName: String {
        guard live.connected else { return "battery.0" }
        return live.charging == true ? "bolt.fill" : "ellipsis"
    }

    /// Green ≥ 50%, yellow 20–49%, red < 20% (feedback from the on-device test). No reading / not
    /// connected / charging stays neutral — there's nothing to warn about yet.
    private var tint: Color {
        guard live.connected, let pct = live.batteryPct else { return HeuteRedesignPalette.ink2 }
        switch pct {
        case ..<20: return HeuteRedesignPalette.attn
        case ..<50: return HeuteRedesignPalette.warning
        default:    return HeuteRedesignPalette.charge
        }
    }

    /// Below 10% the icon blinks to actually draw attention, not just change colour.
    private var isCritical: Bool {
        guard live.connected, let pct = live.batteryPct else { return false }
        return pct < 10
    }

    private func startBlinkIfNeeded() {
        guard isCritical, !reduceMotion else { blinkOn = true; return }
        // Faster than `StrandMotion.breathe` (3.2s, ambient) — a low-battery blink needs to actually
        // read as an alert, so this matches `StrandMotion.pulse`'s own 0.6s duration, repeated
        // (`Animation` doesn't expose its duration back out, so the value is duplicated here).
        withAnimation(Animation.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
            blinkOn = false
        }
    }

    private var accessibilityText: String {
        guard live.connected else { return String(localized: "Strap battery, strap not connected") }
        guard let pct = live.batteryPct else {
            return live.charging == true
                ? String(localized: "Strap battery charging, no reading yet")
                : String(localized: "Strap battery, no reading yet")
        }
        let n = Int(pct.rounded())
        return live.charging == true
            ? String(localized: "Strap battery \(n) percent, charging")
            : String(localized: "Strap battery \(n) percent")
    }
}

// MARK: - Coach chip

/// Coach entry point (feature-spec §5: "immer erreichbar, unabhängig vom Kartenstapel-Zustand"). Reuses
/// `CoachAvatarView` + the same unseen-message dot idiom as `Strand/Screens/CoachEntry.swift`. The host
/// (`HeuteHeaderView`) owns `.coachCover`'s actual presentation — same idiom as `CoachTodayRow`.
struct HeuteCoachChip: View {
    @EnvironmentObject private var coach: AICoachEngine
    @Binding var isPresented: Bool

    var body: some View {
        Button { isPresented = true } label: {
            CoachAvatarView(size: 30)
                .overlay(alignment: .topTrailing) {
                    if coach.hasUnseenCoachMessage {
                        Circle()
                            .fill(HeuteRedesignPalette.effort)
                            .frame(width: 9, height: 9)
                            .overlay(Circle().strokeBorder(HeuteRedesignPalette.bg, lineWidth: 2))
                            .accessibilityHidden(true)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Ask the coach"))
    }
}
