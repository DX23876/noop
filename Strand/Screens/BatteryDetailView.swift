import SwiftUI
import StrandDesign

/// One truth table for every header battery control. A percentage that outlived its Bluetooth link is
/// deliberately offline, never a current reading.
enum StrapBatteryDisplayState: Equatable {
    case offline
    case pending(charging: Bool)
    case charge(pct: Double, charging: Bool)

    static func resolve(connected: Bool, batteryPct: Double?, charging: Bool?) -> Self {
        guard connected else { return .offline }
        guard let batteryPct else { return .pending(charging: charging == true) }
        return .charge(pct: min(100, max(0, batteryPct)), charging: charging == true)
    }

    /// The canonical level bands. These are the menu-bar stat's thresholds
    /// (`MenuBarContent.batteryTone`), which `TodayView`'s own strap-battery row already names as its
    /// source. The dashboard header control used to carry a SECOND set (`<=15` / `<=30`), so the same
    /// strap at 32 % read amber on Today and green on a dashboard. One reading, one band.
    ///
    /// Returns the `StrandTone`, not a `Color`, so the rule itself is testable — SwiftUI catalog colours
    /// compare by provider identity, so an assertion on the rendered colour proves nothing.
    static func tone(_ pct: Double) -> StrandTone {
        switch pct {
        case ..<15: return .critical
        case ..<35: return .warning
        default:    return .positive
        }
    }

    static func tint(_ pct: Double) -> Color { tone(pct).color }
}

/// The strap-battery read-outs shared by every compact surface.
///
/// The badge below existed twice, character for character — `TodayView`'s strap-battery row and the
/// Liquid one, whose comment says outright that it is "Reproduced verbatim from
/// `TodayView.estimateText`". A third copy for the dashboards would have made three places to fix when
/// the wording or the 48-hour boundary moves. (`BatteryDetailView.detailText` stays separate on purpose:
/// a detail screen speaks in full sentences, "About 6 hours remaining", not in a badge.)
enum StrapBatteryCopy {

    /// The compact runtime badge: "~6h left" under two days, "~9 days left" at two days or more.
    ///
    /// Returns nil while charging or without a trusted estimate (no banked discharge yet), so a surface
    /// only ever shows a runtime it can stand behind — #713. Pure: takes plain values rather than
    /// `LiveState`, so it is testable and cannot drag a 1 Hz observation into a view that just wants a
    /// string.
    ///
    /// Both originals carried a singular "~1 day left" arm. It could never run: the day arm starts at 48
    /// hours, and 48 / 24 rounds to 2, so the count is always 2 or more. Folding the copies together is
    /// what surfaced it — the string was dead in both, and is dropped here rather than re-copied.
    static func runtimeBadge(hoursRemaining: Double?, charging: Bool) -> String? {
        guard !charging, let hours = hoursRemaining, hours.isFinite, hours > 0 else { return nil }
        if hours < 48 {
            return String(localized: "~\(Int(hours.rounded()))h left")
        }
        return String(localized: "~\(Int((hours / 24).rounded())) days left")
    }

    /// The level as a whole percent, for the compact controls that show a number beside the ring.
    static func percentText(_ pct: Double) -> String { "\(Int(pct.rounded()))%" }
}

/// Compact exact-fill header control shared by the two reference dashboards.
struct DashboardBatteryButton: View {
    @EnvironmentObject private var live: LiveState
    var size: CGFloat = 36

    private var state: StrapBatteryDisplayState {
        .resolve(connected: live.connected, batteryPct: live.batteryPct, charging: live.charging)
    }

    var body: some View {
        NavigationLink(value: TabRoute.battery) {
            // A reading shows the NUMBER beside the ring. The ring alone carried the level only as a
            // colour and an arc — the percentage existed for VoiceOver but not for anyone looking at the
            // screen, while Today's own row has shown "87% · ~3 days left" all along. Offline and
            // not-yet-read stay a plain circle: there is no number to show, and a capsule sized for one
            // would leave a gap.
            HStack(spacing: 5) {
                ring
                if case .charge(let pct, _) = state {
                    Text(StrapBatteryCopy.percentText(pct))
                        .font(StrandFont.captionNumber)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.trailing, isCharge ? 8 : 0)
            .background {
                if isCharge {
                    Capsule().fill(StrandPalette.surfaceInset)
                        .overlay(Capsule().stroke(StrandPalette.hairline, lineWidth: 1))
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var isCharge: Bool { if case .charge = state { return true }; return false }

    private var ring: some View {
        ZStack {
            Circle().fill(StrandPalette.surfaceInset)
            Circle().stroke(StrandPalette.hairline, lineWidth: 1)
            switch state {
            case .offline:
                Image(systemName: "battery.0").foregroundStyle(StrandPalette.textTertiary)
            case .pending(let charging):
                Image(systemName: charging ? "bolt.fill" : "ellipsis")
                    .foregroundStyle(charging ? StrandPalette.statusPositive : StrandPalette.textSecondary)
            case .charge(let pct, let charging):
                Circle()
                    .trim(from: 0, to: max(0.015, pct / 100))
                    .stroke(tint(pct), style: StrokeStyle(lineWidth: max(2.5, size * 0.09), lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(3)
                Image(systemName: charging ? "bolt.fill" : "battery.100")
                    .font(.system(size: size * 0.32, weight: .semibold))
                    .foregroundStyle(tint(pct))
            }
        }
        .frame(width: size, height: size)
    }

    private func tint(_ pct: Double) -> Color { StrapBatteryDisplayState.tint(pct) }

    private var accessibilityText: String {
        switch state {
        case .offline: return String(localized: "Strap battery, strap not connected")
        case .pending(let charging): return charging
            ? String(localized: "Strap battery charging, no reading yet")
            : String(localized: "Strap battery, no reading yet")
        case .charge(let pct, let charging):
            let base = charging
                ? String(localized: "Strap battery \(Int(pct.rounded())) percent, charging")
                : String(localized: "Strap battery \(Int(pct.rounded())) percent")
            // The runtime is too wide for a header capsule but must not be lost: a screen-reader user
            // gets what Today's row shows in print.
            let runtime = StrapBatteryCopy.runtimeBadge(hoursRemaining: live.batteryEstimate?.hoursRemaining,
                                                        charging: charging)
            return runtime.map { "\(base), \($0)" } ?? base
        }
    }
}

struct BatteryDetailView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState
    @EnvironmentObject private var router: NavRouter

    private var state: StrapBatteryDisplayState {
        .resolve(connected: live.connected, batteryPct: live.batteryPct, charging: live.charging)
    }

    var body: some View {
        ScreenScaffold(title: "Strap battery",
                       subtitle: "A live reading from your connected device.") {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                NoopCard(tint: tint) {
                    VStack(spacing: 18) {
                        batteryGauge
                        Text(statusText)
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        if let detailText {
                            Text(detailText)
                                .font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }

                NoopCard {
                    VStack(spacing: NoopMetrics.rowSpacing) {
                        detailRow("Connection", value: live.connected ? String(localized: "Connected") : String(localized: "Not connected"))
                        if live.connected, let mv = live.batteryMv {
                            Divider().overlay(StrandPalette.hairline)
                            detailRow("Voltage", value: String(format: "%.2f V", Double(mv) / 1000))
                        }
                        if let sample = live.batterySamples.last, live.connected {
                            Divider().overlay(StrandPalette.hairline)
                            detailRow("Last reading", value: Date(timeIntervalSince1970: TimeInterval(sample.ts)).formatted(.relative(presentation: .named)))
                        }
                    }
                }

                NoopButton("Refresh battery", systemImage: "arrow.clockwise", kind: .primary) {
                    model.getBattery()
                }
                .disabled(!live.connected)
                NoopButton("Manage devices", systemImage: "badge.plus.radiowaves.right", kind: .secondary) {
                    router.openDevices()
                }
            }
        }
        .task { if live.connected { model.getBattery() } }
    }

    @ViewBuilder private var batteryGauge: some View {
        switch state {
        case .offline:
            Image(systemName: "battery.0")
                .font(.system(size: 52, weight: .light)).foregroundStyle(StrandPalette.textTertiary)
        case .pending(let charging):
            ZStack {
                Circle().stroke(StrandPalette.hairline, lineWidth: 8)
                Image(systemName: charging ? "bolt.fill" : "ellipsis")
                    .font(StrandFont.title2).foregroundStyle(charging ? StrandPalette.statusPositive : StrandPalette.textSecondary)
            }.frame(width: 112, height: 112)
        case .charge(let pct, let charging):
            GlowRing(fraction: pct / 100, value: pct,
                     format: { "\(Int($0.rounded()))%" }, color: tint,
                     diameter: 132, lineWidth: 11)
                .overlay(alignment: .top) {
                    if charging { Image(systemName: "bolt.fill").foregroundStyle(tint).padding(.top, 23) }
                }
        }
    }

    private var tint: Color {
        guard case .charge(let pct, _) = state else { return StrandPalette.textTertiary }
        if pct <= 15 { return StrandPalette.statusCritical }
        if pct <= 30 { return StrandPalette.statusWarning }
        return StrandPalette.statusPositive
    }

    private var statusText: String {
        switch state {
        case .offline: return String(localized: "Strap not connected")
        case .pending(let charging): return charging ? String(localized: "Charging · waiting for a reading") : String(localized: "Waiting for a battery reading")
        case .charge(_, let charging): return charging ? String(localized: "Charging") : String(localized: "On battery")
        }
    }

    private var detailText: String? {
        switch state {
        case .offline: return String(localized: "Connect your device to request a current battery level.")
        case .pending: return String(localized: "NOOP requested a fresh reading. Some devices report it only after the connection is fully ready.")
        case .charge:
            guard live.charging != true, let estimate = live.batteryEstimate,
                  estimate.hoursRemaining.isFinite, estimate.hoursRemaining > 0 else { return nil }
            if estimate.hoursRemaining < 48 {
                return String(
                    format: String(localized: "About %lld hours remaining"),
                    locale: AppLanguage.activeLocale,
                    Int64(estimate.hoursRemaining.rounded()))
            }
            return String(
                format: String(localized: "About %lld days remaining"),
                locale: AppLanguage.activeLocale,
                Int64((estimate.hoursRemaining / 24).rounded()))
        }
    }

    private func detailRow(_ label: LocalizedStringKey, value: String) -> some View {
        HStack { Text(label).foregroundStyle(StrandPalette.textSecondary); Spacer(); Text(value).foregroundStyle(StrandPalette.textPrimary) }
            .font(StrandFont.subhead)
    }
}
