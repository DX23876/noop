import SwiftUI
import StrandDesign
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Renders the coach's current avatar (#R9) at a given diameter — a curated design-system symbol in a
/// tinted disc, a bundled preset photo (#R-avatar-photos — Svea/Marv, shipped in the app bundle), or the
/// user's own on-device photo clipped to a circle. Observes `CoachIdentityStore` so it updates live
/// wherever it's shown (chat header, Today entry, settings). Shared (macOS + iOS); a user-supplied photo's
/// bytes are loaded from Application Support and never leave the device — a bundled preset photo is part
/// of the app binary, same as any other bundled image asset.
struct CoachAvatarView: View {
    var size: CGFloat = 36
    /// A specific identity to render (settings previews pass presets); nil = the live store identity.
    var identity: CoachIdentity? = nil

    @ObservedObject private var store = CoachIdentityStore.shared

    private var resolved: CoachIdentity { identity ?? store.identity }

    /// The ring stroke scales with the disc so it stays proportionally visible at a much bigger size
    /// (#R-bigger-avatar) — at the existing 26-28pt call sites this stays ≈1pt (unchanged), only exceeding
    /// 1pt above ~28.6pt.
    private var strokeWidth: CGFloat { max(1, size * 0.035) }

    var body: some View {
        Group {
            switch resolved.avatar {
            case .preset(let symbol):
                Image(systemName: symbol)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(StrandPalette.accent)
                    .frame(width: size, height: size)
                    .background(StrandPalette.accent.opacity(0.14), in: Circle())
                    .overlay(Circle().strokeBorder(StrandPalette.accent.opacity(0.22), lineWidth: strokeWidth))
            case .bundled(let name):
                Image(name)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(StrandPalette.hairline, lineWidth: strokeWidth))
            case .photo:
                photoView
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var photoView: some View {
        // Only the LIVE identity's photo is loaded from disk (previews of a preset never carry a photo);
        // a missing/unreadable file falls back to a neutral person mark rather than an empty hole.
        if identity == nil || identity?.avatar == store.identity.avatar,
           let data = store.photoData(), let image = Self.platformImage(data) {
            image
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(StrandPalette.hairline, lineWidth: strokeWidth))
        } else {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(StrandPalette.accent)
                .frame(width: size, height: size)
                .background(StrandPalette.accent.opacity(0.14), in: Circle())
        }
    }

    /// Decode raw bytes into a SwiftUI `Image` on either platform, keeping the store UIKit/AppKit-free.
    private static func platformImage(_ data: Data) -> Image? {
        #if canImport(UIKit)
        guard let ui = UIImage(data: data) else { return nil }
        return Image(uiImage: ui)
        #elseif canImport(AppKit)
        guard let ns = NSImage(data: data) else { return nil }
        return Image(nsImage: ns)
        #else
        return nil
        #endif
    }
}
