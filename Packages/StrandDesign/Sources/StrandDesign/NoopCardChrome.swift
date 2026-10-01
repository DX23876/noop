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
    public static func resolve(kind: NoopCardKind,
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

public extension EnvironmentValues {
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
