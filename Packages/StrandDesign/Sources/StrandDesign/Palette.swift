import SwiftUI

// MARK: - Hex Color Helper

public extension Color {
    /// Parse a hex string ("#0B0D12" / "0B0D12" RGB, or "#AARRGGBB"/"RRGGBBAA" RGBA) to sRGB
    /// components in 0...1. Shared by `Color(hex:)` and the dynamic `Color(light:dark:)` provider.
    static func sRGBComponents(hex: String) -> (r: Double, g: Double, b: Double, a: Double) {
        let raw = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: raw).scanHexInt64(&int)
        switch raw.count {
        case 8: // RRGGBBAA
            return (Double((int >> 24) & 0xFF) / 255.0, Double((int >> 16) & 0xFF) / 255.0,
                    Double((int >> 8) & 0xFF) / 255.0, Double(int & 0xFF) / 255.0)
        default: // RRGGBB (6) and any fallback
            return (Double((int >> 16) & 0xFF) / 255.0, Double((int >> 8) & 0xFF) / 255.0,
                    Double(int & 0xFF) / 255.0, 1.0)
        }
    }

    /// Create a Color from a hex string like "#0B0D12" or "0B0D12" (RGB) or "#AARRGGBB" / "RRGGBBAA".
    /// Supported lengths: 6 (RGB), 8 (RGBA).
    init(hex: String) {
        let c = Color.sRGBComponents(hex: hex)
        self.init(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a)
    }

    /// A colour that resolves to `light` or `dark` (both hex strings) per the active appearance.
    /// Backed by a `UIColor`/`NSColor` dynamic provider, so a single token automatically re-resolves
    /// at every one of its call sites when the colour scheme flips — no per-view environment plumbing.
    /// This is the whole light-theme strategy: only the token definitions change, never the call sites.
    init(light: String, dark: String) {
        #if canImport(UIKit)
        self.init(UIColor { trait in
            let c = Color.sRGBComponents(hex: trait.userInterfaceStyle == .dark ? dark : light)
            return UIColor(red: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: CGFloat(c.a))
        })
        #elseif canImport(AppKit)
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let c = Color.sRGBComponents(hex: isDark ? dark : light)
            return NSColor(srgbRed: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: CGFloat(c.a))
        })
        #else
        self.init(hex: dark)
        #endif
    }
}

// MARK: - Strand Palette
//
// The "Titanium & Gold" re-skin: a premium dark theme built on a deep navy canvas with
// per-domain accent "colour worlds" (Charge = gold, Effort = amber, Rest = blue,
// Stress = blue→gold→orange). GOLD is the dominant brand anchor; titanium drives the
// neutral chrome (tiles, avatars, icons).
//
// PUBLIC API IS FROZEN: every property name below is depended on by screens across
// macOS / iOS, so the names never change — only the VALUES were re-themed. New
// Titanium & Gold tokens (gold ramp, titanium ramp, gradients) are ADDED at the end
// of the type; nothing existing was removed or renamed.

public enum StrandPalette {

    // MARK: Surfaces — deep navy canvas, tinted frosted cards
    // Background is a near-black navy (NOT pure black); cards float just above it.
    public static let surfaceBase    = Color(light: "#F4F1EA", dark: "#070C16") // canvas: warm paper / deep navy
    public static let surfaceRaised  = Color(light: "#FFFFFF", dark: "#111B2A") // card fill: white / frosted navy
    public static let surfaceOverlay = Color(light: "#FFFFFF", dark: "#15243C") // popovers / sheets / tooltips
    public static let surfaceInset   = Color(light: "#ECE7DC", dark: "#16202F") // wells / chart insets / segmented track
    public static let hairline       = Color(light: "#E4DECF", dark: "#21304A") // soft 1px border
    public static let hairlineStrong = Color(light: "#D2C9B6", dark: "#2E3C57") // hover / emphasis border

    // MARK: Text — deep navy-ink on paper / cool off-white on navy
    public static let textPrimary    = Color(light: "#1A2230", dark: "#F4F6F8")
    public static let textSecondary  = Color(light: "#4C5564", dark: "#C8CFD8")
    public static let textTertiary   = Color(light: "#7C8696", dark: "#8A94A4")

    // MARK: Glow — ambient bloom behind heroes / charts (additive on dark; faint warm on light)
    public static let glowAmbient    = Color(light: "#F0E4C0", dark: "#3A2D0A")

    // MARK: Accent — GOLD brand anchor (chrome + the Charge world). Deepened on light for legibility on white.
    public static let accent         = Color(light: "#B07D17", dark: "#E8B84B") // brand gold
    public static let accentHover    = Color(light: "#946612", dark: "#FCEBA8")
    public static let accentMuted    = Color(light: "#F4E8C8", dark: "#2A2210") // selected-row tint
    /// Focus ring color (legible gold in both schemes).
    public static let focusRing      = Color(light: "#C8902F", dark: "#E8B84B")
    /// Opacity for dimmed/disabled sections (shared so screens don't invent their own value).
    public static let disabledOpacity: Double = 0.45

    // MARK: Recovery / Charge gradient — the gold "Charge" colour world.
    // A single warm metal ramp: a deep bronze floor climbs through brand gold into a
    // bright champagne peak — no green anywhere; depleted reads as dim gold, not coral.
    // 0.00 bronze → 0.30 antique gold → 0.55 brand gold → 0.78 soft gold → 1.00 champagne.
    public static let recovery000 = Color(light: "#8F6212", dark: "#C8902F") // depleted — bronze
    public static let recovery030 = Color(light: "#A87718", dark: "#D9A23E") // low — antique gold
    public static let recovery055 = Color(light: "#C28E26", dark: "#E8B84B") // moderate — brand gold
    public static let recovery078 = Color(light: "#D2A23A", dark: "#F2CE6E") // primed — soft gold
    public static let recovery100 = Color(light: "#E0B44C", dark: "#FCEBA8") // peak — champagne (deepened on light)

    /// Ordered gradient stops for the recovery scale (location + color).
    public static let recoveryStops: [Gradient.Stop] = [
        .init(color: recovery000, location: 0.00),
        .init(color: recovery030, location: 0.30),
        .init(color: recovery055, location: 0.55),
        .init(color: recovery078, location: 0.78),
        .init(color: recovery100, location: 1.00),
    ]

    /// The signature recovery gradient (bronze → champagne).
    public static let recoveryGradient = Gradient(stops: recoveryStops)

    // MARK: Strain / Effort ramp — the amber "Effort" colour world.
    // Deep ember → warm amber → bright amber → soft amber peak: heat/output, all in the
    // Effort accent family rather than veering into magenta.
    public static let strain000 = Color(light: "#7E460E", dark: "#9C5A14") // deep ember
    public static let strain033 = Color(light: "#A4621B", dark: "#C2762A") // warm amber
    public static let strain066 = Color(light: "#C2792E", dark: "#D98A3D") // bright amber
    public static let strain100 = Color(light: "#D89240", dark: "#F0A85A") // soft amber peak

    public static let strainStops: [Gradient.Stop] = [
        .init(color: strain000, location: 0.00),
        .init(color: strain033, location: 0.33),
        .init(color: strain066, location: 0.66),
        .init(color: strain100, location: 1.00),
    ]

    /// The strain gradient (output / heat).
    public static let strainGradient = Gradient(stops: strainStops)

    // MARK: Sleep stages — the blue "Rest" colour world. Distinct blues + a pale-slate
    // awake band so the stages read clearly apart on the frosted card (fixes #345).
    public static let sleepAwake = Color(light: "#97A2B2", dark: "#C2CCDA") // mid/pale slate (out of bed)
    public static let sleepLight = Color(light: "#3A80D6", dark: "#4A90E2") // light blue
    public static let sleepDeep  = Color(light: "#234F9E", dark: "#2F6FCB") // deep blue (clearly darker than Light)
    public static let sleepREM   = Color(light: "#5790DA", dark: "#6FA8E8") // bright blue

    // MARK: HR zones — cool→warm ramp tuned to the Titanium & Gold worlds (no green); deepened on light.
    public static let zone1 = Color(light: "#3A80D6", dark: "#4A90E2") // easy — blue
    public static let zone2 = Color(light: "#2E92B4", dark: "#3FA9C9") // teal
    public static let zone3 = Color(light: "#C28E26", dark: "#E8B84B") // gold
    public static let zone4 = Color(light: "#C2792E", dark: "#D98A3D") // amber
    public static let zone5 = Color(light: "#C84E1E", dark: "#E0662F") // max — burnt orange

    /// HR zones indexed 1...5; index 0 mirrors zone1 for convenience.
    public static let hrZones: [Color] = [zone1, zone1, zone2, zone3, zone4, zone5]

    // MARK: Status — never reused as recovery colors.
    public static let statusPositive = Color(light: "#B07D17", dark: "#E8B84B")
    public static let statusWarning  = Color(light: "#C2792E", dark: "#D98A3D")
    public static let statusCritical = Color(light: "#C84E1E", dark: "#E0662F")

    // MARK: Per-metric accents — HRV / SpO₂ / energy / risk, on-brand for Titanium & Gold; deepened on light.
    public static let metricCyan   = Color(light: "#2E92B4", dark: "#3FA9C9") // SpO₂ / steps / Apple Health (teal)
    public static let metricPurple = Color(light: "#3A80D6", dark: "#4A90E2") // HRV (shares the Rest world — blue)
    public static let metricAmber  = Color(light: "#C2792E", dark: "#D98A3D") // calories (shares the Effort world)
    public static let metricRose   = Color(light: "#C84E1E", dark: "#E0662F") // risk / heart rate / low recovery

    // MARK: - Titanium & Gold domain "colour worlds" (NEW)
    //
    // Each daily score owns a two-stop accent gradient (deep → bright) plus a glow.
    // These drive the layered gauges, frosted-card tints and scenic heroes. Charge
    // owns the brand gold; Effort the amber ramp; Rest the blue scale.

    /// Charge (recovery) — gold world.
    public static let chargeColor      = Color(light: "#B88421", dark: "#E8B84B")
    public static let chargeDeep       = Color(light: "#8F6212", dark: "#C8902F")
    public static let chargeBright      = Color(light: "#E0B44C", dark: "#FCEBA8")
    public static let chargeGlow       = Color(light: "#C8902F", dark: "#E8B84B")
    /// Diagonal accent pair for the Charge card wash + gauge stroke (deep → bright).
    public static let chargeGradient   = Gradient(colors: [chargeDeep, chargeBright])

    /// Effort (strain) — amber world.
    public static let effortColor      = Color(light: "#B26A1C", dark: "#D98A3D")
    public static let effortDeep       = Color(light: "#7E460E", dark: "#9C5A14")
    public static let effortBright      = Color(light: "#D89240", dark: "#F0A85A")
    public static let effortGlow       = Color(light: "#B26A1C", dark: "#D98A3D")
    public static let effortGradient   = Gradient(colors: [effortDeep, effortBright])

    /// Rest (sleep) — blue world.
    public static let restColor        = Color(light: "#3A80D6", dark: "#4A90E2")
    public static let restDeep         = Color(light: "#234F9E", dark: "#2F6FCB")
    public static let restBright        = Color(light: "#5790DA", dark: "#6FA8E8")
    public static let restGlow         = Color(light: "#3A80D6", dark: "#4A90E2")
    public static let restGradient     = Gradient(colors: [restDeep, restBright])

    /// Stress — blue→gold→orange world (used by StressView's accents).
    public static let stressColor      = Color(light: "#B88421", dark: "#E8B84B")
    public static let stressDeep       = Color(light: "#3A80D6", dark: "#4A90E2")
    public static let stressBright      = Color(light: "#C84E1E", dark: "#E0662F")
    public static let stressGlow       = Color(light: "#B88421", dark: "#E8B84B")
    /// 3-stop gauge ramp: calm blue → balanced gold → high burnt-orange.
    public static let stressGradient   = Gradient(colors: [stressDeep, stressColor, stressBright])

    // MARK: Scenic background (NEW) — detail-screen hero gradient + starfield.
    /// Radial canvas: lit center → deep edge. Used by `ScenicHeroBackground` (warm-lit on light).
    public static let scenicCenter     = Color(light: "#FBF6EA", dark: "#15243C")
    public static let scenicEdge       = Color(light: "#EDE6D6", dark: "#0A1322")
    /// Star tint for the scenic starfield (very faint on light; the hero suppresses stars there).
    public static let scenicStar       = Color(light: "#D8CDB6", dark: "#C8CFD8")

    /// Frosted-card tint endpoints (white→warm on light; the accent wash sits over them).
    public static let cardFillTop      = Color(light: "#FFFFFF", dark: "#15243C")
    public static let cardFillBottom   = Color(light: "#FAF7F0", dark: "#0B1424")

    // MARK: - Titanium & Gold core tokens (NEW)
    //
    // The brand gold ramp (buttons, ring fills, FAB, active chrome) and the neutral
    // titanium ramp (tiles, avatars, icon plates). Same names + hexes on Android so
    // Apple and Android match byte-for-byte.

    /// Brand gold — primary accent. Gold FILLS stay bright (dark text on them is legible in both schemes);
    /// only a hair deeper on light so the fill doesn't wash out against white.
    public static let gold          = Color(light: "#DBA52A", dark: "#E8B84B")
    /// Bright champagne — gold highlight / hover.
    public static let goldLight     = Color(light: "#ECC766", dark: "#FCEBA8")
    /// Deep bronze — gold shadow / low stop.
    public static let goldDeep      = Color(light: "#9A6B12", dark: "#C8902F")
    /// Near-black brown — text / icons placed ON gold surfaces (scheme-invariant; gold fills stay gold).
    public static let goldDeepText  = Color(hex: "#3A2708")
    /// The bright core dot at a gauge arc tip / sparkline head. White reads as a highlight on the dark
    /// canvas; on light it would vanish into the white card, so it flips to a deep ink that reads as a
    /// crisp centre on the (deepened) coloured tip bead.
    public static let tipCore       = Color(light: "#241B06", dark: "#FFFFFF")
    /// High-vis signal yellow — sparing emphasis (badges / alerts); deepened on light to stay visible.
    public static let signalYellow  = Color(light: "#E8A800", dark: "#FFD63D")
    /// 135–155° gold ramp for buttons, ring fills, FAB (light → gold → deep).
    public static let goldGradient  = Gradient(colors: [goldLight, gold, goldDeep])

    /// Brushed-titanium ramp (top highlight → mid body → low → deep) for tiles, avatars and icon plates.
    /// Shifted to a MID-grey ramp on light so brushed-metal tiles stay visible against white cards.
    public static let titaniumTop   = Color(light: "#DDE1E6", dark: "#F1F3F5")
    public static let titaniumMid   = Color(light: "#BBC2C9", dark: "#C9CFD4")
    public static let titaniumLow   = Color(light: "#98A0A8", dark: "#969DA4")
    public static let titaniumDeep  = Color(hex: "#6B737B")
    /// 150° titanium ramp for tiles / avatars / icon plates.
    public static let titaniumGradient = Gradient(colors: [titaniumTop, titaniumMid, titaniumLow, titaniumDeep])

    // MARK: - Sampling helpers

    /// Sample the recovery gradient (bronze → champagne) at a recovery score 0...100.
    /// Returns the exact interpolated color used everywhere recovery is tinted.
    public static func recoveryColor(_ score: Double) -> Color {
        sample(stops: recoveryStops, at: score / 100.0)
    }

    /// Sample the strain ("Effort") gradient at a value on NOOP's 0...100 Effort scale.
    public static func strainColor(_ strain: Double) -> Color {
        sample(stops: strainStops, at: strain / 100.0)
    }

    /// Effort tint sampled by a 0...1 fraction (e.g. value/scaleMax), spreading the full ember→amber
    /// ramp. Prefer this for gauge tips / value-tinted accents so a high Effort reads as bright amber
    /// rather than ember. `strainColor(_:)` stays for callers holding a 0...100 value.
    public static func effortTint(fraction: Double) -> Color {
        sample(stops: strainStops, at: min(max(fraction, 0), 1))
    }

    /// The state word for a recovery score, per spec §9.3.
    /// DEPLETED · LOW · MODERATE · PRIMED · PEAK
    public static func recoveryState(_ score: Double) -> String {
        switch score {
        case ..<25:  return "DEPLETED"
        case ..<50:  return "LOW"
        case ..<70:  return "MODERATE"
        case ..<88:  return "PRIMED"
        default:     return "PEAK"
        }
    }

    /// HR-zone color for a 0...5 zone index (clamped).
    public static func hrZoneColor(_ zone: Int) -> Color {
        let z = max(1, min(5, zone))
        return hrZones[z]
    }

    /// Color for a sleep stage by canonical name (awake/light/deep/rem).
    public static func sleepStageColor(_ stage: SleepStage) -> Color {
        switch stage {
        case .awake: return sleepAwake
        case .light: return sleepLight
        case .deep:  return sleepDeep
        case .rem:   return sleepREM
        }
    }

    // MARK: - Linear gradient stop interpolation

    /// Interpolate a set of gradient stops at a normalized position 0...1.
    /// Clamps out-of-range positions to the end stops.
    public static func sample(stops: [Gradient.Stop], at position: Double) -> Color {
        guard let first = stops.first else { return .clear }
        guard stops.count > 1 else { return first.color }
        let t = min(max(position, 0.0), 1.0)

        // Find the bracketing pair.
        var lower = stops[0]
        var upper = stops[stops.count - 1]
        for i in 0..<(stops.count - 1) {
            let a = stops[i]
            let b = stops[i + 1]
            if t >= a.location && t <= b.location {
                lower = a
                upper = b
                break
            }
        }
        let span = upper.location - lower.location
        let localT = span > 0 ? (t - lower.location) / span : 0
        return interpolate(lower.color, upper.color, localT)
    }

    /// Linear-interpolate two colors in sRGB space.
    static func interpolate(_ a: Color, _ b: Color, _ t: Double) -> Color {
        let ca = a.rgbaComponents
        let cb = b.rgbaComponents
        let tt = min(max(t, 0.0), 1.0)
        return Color(
            .sRGB,
            red:   ca.r + (cb.r - ca.r) * tt,
            green: ca.g + (cb.g - ca.g) * tt,
            blue:  ca.b + (cb.b - ca.b) * tt,
            opacity: ca.a + (cb.a - ca.a) * tt
        )
    }
}

// MARK: - Sleep stage enum (shared with Hypnogram)

public enum SleepStage: String, CaseIterable, Sendable {
    case awake
    case light
    case deep
    case rem

    /// Display label.
    public var label: String {
        switch self {
        case .awake: return "Awake"
        case .light: return "Light"
        case .deep:  return "Deep"
        case .rem:   return "REM"
        }
    }

    /// Vertical band order (top = awake, bottom = deep) for hypnogram layout.
    public var bandRank: Int {
        switch self {
        case .awake: return 0
        case .rem:   return 1
        case .light: return 2
        case .deep:  return 3
        }
    }
}

// MARK: - Color component extraction

extension Color {
    /// Resolve to sRGB RGBA components in 0...1. Works on macOS 13+ via platform color bridge.
    var rgbaComponents: (r: Double, g: Double, b: Double, a: Double) {
        #if canImport(AppKit)
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b), Double(a))
        #elseif canImport(UIKit)
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b), Double(a))
        #else
        return (0, 0, 0, 1)
        #endif
    }
}

#if DEBUG
#Preview("Palette") {
    ScrollView {
        VStack(alignment: .leading, spacing: 24) {
            swatchRow("Surfaces", [
                ("base", StrandPalette.surfaceBase),
                ("raised", StrandPalette.surfaceRaised),
                ("overlay", StrandPalette.surfaceOverlay),
                ("inset", StrandPalette.surfaceInset),
                ("hairline", StrandPalette.hairline),
                ("hairline.strong", StrandPalette.hairlineStrong),
            ])
            swatchRow("Text", [
                ("primary", StrandPalette.textPrimary),
                ("secondary", StrandPalette.textSecondary),
                ("tertiary", StrandPalette.textTertiary),
            ])
            swatchRow("Accent", [
                ("accent", StrandPalette.accent),
                ("hover", StrandPalette.accentHover),
                ("muted", StrandPalette.accentMuted),
            ])
            swatchRow("Gold", [
                ("gold", StrandPalette.gold),
                ("light", StrandPalette.goldLight),
                ("deep", StrandPalette.goldDeep),
                ("deepText", StrandPalette.goldDeepText),
                ("signal", StrandPalette.signalYellow),
            ])
            swatchRow("Titanium", [
                ("top", StrandPalette.titaniumTop),
                ("mid", StrandPalette.titaniumMid),
                ("low", StrandPalette.titaniumLow),
                ("deep", StrandPalette.titaniumDeep),
            ])
            VStack(alignment: .leading, spacing: 8) {
                Text("RECOVERY GRADIENT").font(.caption).foregroundStyle(StrandPalette.textTertiary)
                LinearGradient(gradient: StrandPalette.recoveryGradient, startPoint: .leading, endPoint: .trailing)
                    .frame(height: 36).clipShape(RoundedRectangle(cornerRadius: 8))
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("STRAIN RAMP").font(.caption).foregroundStyle(StrandPalette.textTertiary)
                LinearGradient(gradient: StrandPalette.strainGradient, startPoint: .leading, endPoint: .trailing)
                    .frame(height: 36).clipShape(RoundedRectangle(cornerRadius: 8))
            }
            swatchRow("Sleep stages", [
                ("awake", StrandPalette.sleepAwake),
                ("light", StrandPalette.sleepLight),
                ("deep", StrandPalette.sleepDeep),
                ("REM", StrandPalette.sleepREM),
            ])
            swatchRow("HR zones", [
                ("Z1", StrandPalette.zone1), ("Z2", StrandPalette.zone2),
                ("Z3", StrandPalette.zone3), ("Z4", StrandPalette.zone4),
                ("Z5", StrandPalette.zone5),
            ])
        }
        .padding(24)
    }
    .frame(width: 520, height: 760)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}

@ViewBuilder
private func swatchRow(_ title: String, _ items: [(String, Color)]) -> some View {
    VStack(alignment: .leading, spacing: 8) {
        Text(title.uppercased())
            .font(.caption)
            .foregroundStyle(StrandPalette.textTertiary)
        HStack(spacing: 10) {
            ForEach(items, id: \.0) { name, color in
                VStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(color)
                        .frame(width: 64, height: 48)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(StrandPalette.hairline, lineWidth: 1))
                    Text(name).font(.system(size: 9)).foregroundStyle(StrandPalette.textSecondary)
                }
            }
        }
    }
}
#endif
