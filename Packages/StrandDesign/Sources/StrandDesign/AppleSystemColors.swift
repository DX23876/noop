import SwiftUI

/// Apple's own dynamic system colors as fixed light/dark hex pairs, shared by every "Apple Health
/// style" icon-recoloring feature (`MoreRowAppleHealthColors`, `CoachIconColors`) — not general design
/// tokens (those live in `Palette.swift`'s `StrandPalette`), just the literal Apple system-color values
/// those features draw from.
extension Color {
    static let systemRed    = Color(light: "#FF3B30", dark: "#FF453A")
    static let systemOrange = Color(light: "#FF9500", dark: "#FF9F0A")
    static let systemYellow = Color(light: "#FFCC00", dark: "#FFD60A")
    static let systemGreen  = Color(light: "#34C759", dark: "#30D158")
    static let systemMint   = Color(light: "#00C7BE", dark: "#66D4CF")
    static let systemTeal   = Color(light: "#30B0C7", dark: "#40C8E0")
    static let systemCyan   = Color(light: "#32ADE6", dark: "#64D2FF")
    static let systemBlue   = Color(light: "#007AFF", dark: "#0A84FF")
    static let systemIndigo = Color(light: "#5856D6", dark: "#5E5CE6")
    static let systemPurple = Color(light: "#AF52DE", dark: "#BF5AF2")
    static let systemPink   = Color(light: "#FF2D55", dark: "#FF375F")
    static let systemBrown  = Color(light: "#A2845E", dark: "#AC8E68")
    static let systemGray   = Color(light: "#8E8E93", dark: "#98989D")
}
