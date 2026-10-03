import SwiftUI

/// What a card is for. The kind decides how loudly its edge speaks, so a settings hub, a chart, a
/// hero and a warning do not all share one grey outline.
public enum NoopCardKind: Sendable, Equatable, CaseIterable {
    /// Lists and hubs that lead somewhere. The fill separates them from the page; no rim, no shadow.
    case navigation
    /// Measurements and charts. The default.
    case data
    /// The one large headline card of a screen.
    case hero
    /// A card that states a condition (warning, notice) or a chosen item. Its rim carries the signal.
    case state
}

/// Resting edge of a card: the rim and the drop shadow. Pure, so every combination of kind,
/// appearance and accessibility setting is testable without a view.
public struct NoopCardChrome: Sendable, Equatable {
    public enum Rim: Sendable, Equatable {
        case none
        /// The neutral 1 pt hairline.
        case hairline
        /// The stronger neutral line, for "Increase Contrast".
        case strong
        /// A thin rim in the card's own tint, the signal of a `.state` card.
        case tinted
        /// The stronger tinted rim, for "Increase Contrast".
        case tintedStrong
    }

    public var rim: Rim
    /// The soft light-mode drop shadow.
    public var shadow: Bool

    /// The light-mode shadow, shared by every card surface. Low opacity and pushed down rather than
    /// spread sideways, so a card lifts off the page from below instead of looking outlined in grey.
    public static let lightShadowOpacity: Double = 0.06
    public static let lightShadowRadius: CGFloat = 8
    public static let lightShadowOffsetY: CGFloat = 5

    public init(rim: Rim, shadow: Bool) {
        self.rim = rim
        self.shadow = shadow
    }

    /// - Parameters:
    ///   - isLight: light appearance.
    ///   - isTransparent: the "Card transparency" setting is below 100 %, so the fill no longer
    ///     separates the card from what is behind it.
    ///   - increasedContrast: the system "Increase Contrast" setting.
    ///   - quietEdges: the iPhone treatment. Other platforms keep the original hairline plus
    ///     light-mode shadow on every card except navigation cards.
    ///   - quietRims: a screen that wants restrained surfaces (Liquid Today) drops the resting rim on
    ///     opaque cards; the fill separates them. A see-through card keeps its hairline, a `.state`
    ///     card keeps its signal, and Increase Contrast keeps every edge.
    public static func resolve(kind: NoopCardKind,
                               isLight: Bool,
                               isTransparent: Bool,
                               increasedContrast: Bool,
                               quietEdges: Bool,
                               quietRims: Bool = false) -> NoopCardChrome {
        let chrome = resolveEdges(kind: kind, isLight: isLight, isTransparent: isTransparent,
                                  increasedContrast: increasedContrast, quietEdges: quietEdges)
        guard quietRims, !increasedContrast, !isTransparent, kind != .state, chrome.rim == .hairline else {
            return chrome
        }
        return NoopCardChrome(rim: .none, shadow: chrome.shadow)
    }

    private static func resolveEdges(kind: NoopCardKind,
                                     isLight: Bool,
                                     isTransparent: Bool,
                                     increasedContrast: Bool,
                                     quietEdges: Bool) -> NoopCardChrome {
        guard quietEdges else {
            // Other platforms keep the original treatment; only navigation cards were ever quiet there.
            return kind == .navigation ? NoopCardChrome(rim: .none, shadow: false)
                                       : NoopCardChrome(rim: .hairline, shadow: isLight)
        }

        if kind == .state {
            return NoopCardChrome(rim: increasedContrast ? .tintedStrong : .tinted, shadow: false)
        }
        if increasedContrast {
            return NoopCardChrome(rim: .strong, shadow: false)
        }
        guard isLight else {
            // Dark keeps its hairline and stays flat; a navigation card is still separated by fill alone.
            return NoopCardChrome(rim: kind == .navigation ? .none : .hairline, shadow: false)
        }
        switch kind {
        case .navigation:
            return NoopCardChrome(rim: isTransparent ? .hairline : .none, shadow: false)
        case .data, .hero:
            return NoopCardChrome(rim: isTransparent ? .hairline : .none, shadow: true)
        case .state:
            return NoopCardChrome(rim: .tinted, shadow: false)
        }
    }
}

private struct NoopCardKindKey: EnvironmentKey {
    static let defaultValue: NoopCardKind = .data
}

/// On by default app-wide since 2026-10-02 (user decision): opaque cards everywhere rest on their
/// fill without the slate hairline. A screen can still opt back in with `.environment(…, false)`.
private struct NoopQuietCardRimsKey: EnvironmentKey {
    static let defaultValue = true
}

public extension EnvironmentValues {
    /// True (the default) for a subtree whose cards rest without a rim (see `NoopCardChrome.resolve`).
    var noopQuietCardRims: Bool {
        get { self[NoopQuietCardRimsKey.self] }
        set { self[NoopQuietCardRimsKey.self] = newValue }
    }

    /// The kind of every card in a subtree that does not name one itself.
    var noopCardKind: NoopCardKind {
        get { self[NoopCardKindKey.self] }
        set { self[NoopCardKindKey.self] = newValue }
    }
}

public extension View {
    /// Sets the default card kind for a whole screen subtree, for example `.navigation` on a hub.
    func noopCardKind(_ kind: NoopCardKind) -> some View {
        environment(\.noopCardKind, kind)
    }
}

// MARK: - Resting rim for pills, frames and secondary surfaces

/// The hairline a pill, frame or secondary button used to draw unconditionally. Under the app-wide
/// quiet edges it is drawn only for Increase Contrast (or where a subtree opts out of quiet rims).
/// Input fields and selection outlines do NOT use this: their edge carries meaning.
public struct NoopRestingRim<S: InsettableShape>: View {
    let shape: S
    let lineWidth: CGFloat
    @Environment(\.noopQuietCardRims) private var quietRims
    @Environment(\.colorSchemeContrast) private var contrast

    public init(_ shape: S, lineWidth: CGFloat = 1) {
        self.shape = shape
        self.lineWidth = lineWidth
    }

    public var body: some View {
        if !quietRims || contrast == .increased {
            shape.strokeBorder(StrandPalette.hairline, lineWidth: lineWidth)
        }
    }
}

public extension InsettableShape {
    /// See `NoopRestingRim`.
    func noopRestingRim(lineWidth: CGFloat = 1) -> NoopRestingRim<Self> {
        NoopRestingRim(self, lineWidth: lineWidth)
    }
}
