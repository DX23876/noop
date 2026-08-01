import SwiftUI

// MARK: - Heute-Screen redesign palette (docs/fork/design/design-spec.md, docs/fork/design/mockup-heute.html)
//
// A SEPARATE, additive token set — `StrandPalette` is untouched. Two reasons this can't just reuse
// `StrandPalette`:
//   1. `StrandPalette.chargeColor`/`.effortColor`/`.restColor` are chart-style-DEPENDENT computed
//      properties (they vary with the user's classic/health/aurora/sunset/forest/titanium/signature
//      setting); only `.signature` happens to equal this screen's green/blue/violet. The redesign
//      spec requires these three FIXED regardless of chart style ("reserviert" — design-spec §0.4).
//   2. The redesign's near-black tile/background/ink scale doesn't match any existing `StrandPalette`
//      surface token (e.g. `surfaceBase` dark `#121518` vs. this screen's `bg` `#000000`).
// Values are transcribed verbatim from the mockup's `:root[data-theme]` blocks — mockup is the binding
// visual reference where design-spec.md's prose is imprecise.
public enum HeuteRedesignPalette {
    public static let bg       = Color(light: "#F5F5F3", dark: "#000000")
    public static let tile     = Color(light: "#FFFFFF", dark: "#121514")
    public static let tile2    = Color(light: "#FAFAF8", dark: "#191D1B")
    public static let sheet    = Color(light: "#FFFFFF", dark: "#171B19")
    public static let line     = Color(light: "#E4E4E0", dark: "#262B29")
    public static let ink      = Color(light: "#0A0C0B", dark: "#FFFFFF")
    public static let ink2     = Color(light: "#5E6562", dark: "#9AA09D")
    public static let ink3     = Color(light: "#8A908D", dark: "#69706D")
    public static let track    = Color(light: "#E8E8E4", dark: "#232826")

    /// The single warning colour shared by all three ActivityStatus exception states (Sick/Injured/
    /// OnBreak) — deliberately one colour, not four (design-spec §6): green collides with Charge,
    /// orange/gold collides with Fitness-Age gold. The icon distinguishes the states, not colour.
    public static let attn     = Color(light: "#C24A2E", dark: "#E3684A")

    /// Mid-level warning yellow (battery 20–49%, distinct from `attn`'s red-orange). Same hex pair as
    /// `StrandPalette.statusWarning`'s `.health` case — a proven, tested warning yellow already in this
    /// codebase — used as a fixed literal here rather than the chart-style-dependent property.
    public static let warning  = Color(light: "#FFCC00", dark: "#FFD60A")

    /// Ring family colours — fixed, reserved (design-spec §0.4), independent of the chart-style setting.
    public static let charge   = Color(light: "#0C8F62", dark: "#31E39C")
    public static let effort   = Color(light: "#0A63B8", dark: "#3AA0FF")
    public static let rest     = Color(light: "#5546C4", dark: "#8C7BFF")

    /// Live heart-rate thread tint — a fixed HR red, deliberately its OWN token rather than reusing
    /// `icHrv` (the HRV vital badge) so two different signals don't share a colour on one screen, and not
    /// `StrandPalette` (chart-style-dependent). Same hue as `icHrv` but semantically distinct.
    public static let heart    = Color(light: "#E23A57", dark: "#FF4D6D")

    // MARK: Per-metric icon-badge accents (design-spec §4 table) — own mini-palette, deliberately
    // separate from the ring family colours above to avoid collisions. Steps/Activity has no accent
    // here on purpose (neutral `ink3`, design-spec §4: "kein Akzent").
    public static let icHrv    = Color(light: "#E23A57", dark: "#FF4D6D")
    public static let icRhr    = Color(light: "#DB6E1E", dark: "#FF8A3D")
    public static let icResp   = Color(light: "#0E9E8F", dark: "#2DD4BF")
    public static let icSpo2   = Color(light: "#0E8FB0", dark: "#22B8E0")
    public static let icFitage = Color(light: "#B07908", dark: "#F0B441")
    /// Added for weight/calories parity with the old Today grid's `KeyMetric` set (feedback from the
    /// on-device test) — a cool slate blue, distinct from Effort's blue and SpO₂'s cyan.
    public static let icWeight   = Color(light: "#4A6FA5", dark: "#6FA3D8")
    /// A warm bronze/tan, distinct from HRV's rose, RHR's orange, and Fitness-Age's gold.
    public static let icCalories = Color(light: "#8B5A2B", dark: "#D9954F")
}
