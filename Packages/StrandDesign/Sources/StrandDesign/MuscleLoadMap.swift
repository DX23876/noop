import SwiftUI

// MARK: - Muscle load map
//
// A geometric body diagram whose regions are shaded by how much WORK each one has taken in a recent
// window. Front and back.
//
// ## What this shows, and what it deliberately does not
//
// It shows LOAD — sets performed — not recovery. The distinction is the whole reason this component
// exists in this form. Apps that put a percentage on each muscle ("Back 94 %") are not reporting a
// measurement: a freshness figure can only be produced by assuming a decay curve over 48-72 hours and
// applying it to everyone, which is exactly the kind of universal formula this project rules out. What
// a training log can support is "you did twelve sets of this, most recently on Tuesday". That is what
// this draws.
//
// So there is no time term in the colour AT ALL. How long ago a muscle was worked is a separate fact,
// reported as text next to the map rather than folded into the same channel — fusing "how much" and
// "how long ago" into one number is precisely the step that turns two measurements into one model.
//
// ## Why the shapes are blocks
//
// The regions are rounded rectangles and capsules in a normalised unit box, not an anatomical
// drawing. That is a deliberate choice and not a shortcut: a realistic muscle illustration implies an
// anatomical precision the underlying data does not have (Hevy attributes a set to ONE primary group
// per exercise), and it would also be someone else's artwork. Blocks read at a glance, scale to any
// size, tint from the palette, and promise exactly as much as they can deliver.
//
// The component is pure presentation: it takes intensities already computed by the caller and renders
// them. It contains no notion of sets, days, or muscles-as-data — only regions to fill.

public struct MuscleLoadMap: View {

    /// A region of the diagram. Named for the body, not for any one data source, so the design package
    /// stays free of `WhoopStore` (it has no dependencies, deliberately) and the app does the mapping.
    public enum Region: String, Sendable, CaseIterable {
        case neck, traps, shoulders, chest, biceps, triceps, forearms, abdominals
        case upperBack, lats, lowerBack
        case glutes, quadriceps, hamstrings, calves, adductors, abductors
    }

    /// Which way the body faces. Some regions appear on both sides (shoulders, forearms, calves,
    /// traps): they are drawn on whichever view shows them, and a muscle absent from one side is
    /// simply not drawn there — never drawn dim, which would read as "trained a little".
    public enum Face: String, Sendable, CaseIterable {
        case front, back
        public var label: String {
            switch self {
            case .front: return String(localized: "Front", bundle: .module)
            case .back:  return String(localized: "Back", bundle: .module)
            }
        }
    }

    /// 0...1 per region. A region absent from the dictionary is drawn as untouched — which is a real
    /// statement ("nothing here"), not missing data.
    public var intensity: [Region: Double]
    public var face: Face
    /// The tint the filled regions take. Passed in so the map inherits whatever domain it sits in
    /// rather than hardcoding a colour.
    public var tint: Color
    /// Called when a region is tapped, so the caller can scroll its list to the matching row.
    public var onSelect: ((Region) -> Void)?
    /// Reads out each region's value for VoiceOver; the map is otherwise a picture of numbers.
    public var accessibilityValue: (Region) -> String

    public init(intensity: [Region: Double],
                face: Face,
                tint: Color = DomainTheme.effort.color,
                onSelect: ((Region) -> Void)? = nil,
                accessibilityValue: @escaping (Region) -> String = { _ in "" }) {
        self.intensity = intensity
        self.face = face
        self.tint = tint
        self.onSelect = onSelect
        self.accessibilityValue = accessibilityValue
    }

    public var body: some View {
        GeometryReader { geo in
            // The diagram keeps a fixed 1:2 aspect whatever box it is given, so the body never
            // stretches: it is centred in the available space instead.
            let h = geo.size.height
            let w = min(geo.size.width, h * Self.aspect)
            let originX = (geo.size.width - w) / 2

            ZStack(alignment: .topLeading) {
                ForEach(Self.silhouette, id: \.self) { part in
                    shape(part, in: w, h: h, x: originX)
                        .fill(StrandPalette.surfaceInset)
                }
                // Indexed, NOT keyed by region: a paired muscle contributes two blocks with the same
                // region, and `id: \.region` made SwiftUI treat them as one item and draw a
                // half-shaded body — every left side present, every right side missing.
                ForEach(Array(regions.enumerated()), id: \.offset) { _, item in
                    shape(item.part, in: w, h: h, x: originX)
                        .fill(fill(for: item.region))
                        .overlay(
                            shape(item.part, in: w, h: h, x: originX)
                                .stroke(StrandPalette.hairline, lineWidth: 0.5)
                        )
                        .contentShape(shape(item.part, in: w, h: h, x: originX))
                        .onTapGesture { onSelect?(item.region) }
                        .accessibilityElement()
                        .accessibilityLabel(Text(label(item.region)))
                        .accessibilityValue(Text(accessibilityValue(item.region)))
                }
            }
        }
        .aspectRatio(Self.aspect, contentMode: .fit)
    }

    /// Untouched regions take the inset surface rather than a faint tint. A barely-tinted block would
    /// read as "a little work", and zero is not a little.
    private func fill(for region: Region) -> Color {
        let value = intensity[region] ?? 0
        guard value > 0 else { return StrandPalette.surfaceInset }
        // Floor the opacity well clear of the background so one set is visibly more than none, then
        // scale the rest linearly. No curve: a curve would imply a dose-response shape this component
        // has no business asserting.
        return tint.opacity(0.28 + 0.72 * min(1, value))
    }

    private var regions: [(region: Region, part: Part)] {
        Self.parts(for: face)
    }

    private func label(_ region: Region) -> String {
        switch region {
        case .neck:        return String(localized: "Neck", bundle: .module)
        case .traps:       return String(localized: "Traps", bundle: .module)
        case .shoulders:   return String(localized: "Shoulders", bundle: .module)
        case .chest:       return String(localized: "Chest", bundle: .module)
        case .biceps:      return String(localized: "Biceps", bundle: .module)
        case .triceps:     return String(localized: "Triceps", bundle: .module)
        case .forearms:    return String(localized: "Forearms", bundle: .module)
        case .abdominals:  return String(localized: "Abdominals", bundle: .module)
        case .upperBack:   return String(localized: "Upper back", bundle: .module)
        case .lats:        return String(localized: "Lats", bundle: .module)
        case .lowerBack:   return String(localized: "Lower back", bundle: .module)
        case .glutes:      return String(localized: "Glutes", bundle: .module)
        case .quadriceps:  return String(localized: "Quadriceps", bundle: .module)
        case .hamstrings:  return String(localized: "Hamstrings", bundle: .module)
        case .calves:      return String(localized: "Calves", bundle: .module)
        case .adductors:   return String(localized: "Adductors", bundle: .module)
        case .abductors:   return String(localized: "Abductors", bundle: .module)
        }
    }

    // MARK: - Geometry
    //
    // Everything below is in a unit box: x and y both 0...1, y downward, the body centred on x = 0.5.
    // A region is one or more blocks, because a paired muscle needs a left and a right.

    /// Width divided by height. A standing figure is about half as wide as it is tall.
    static let aspect: CGFloat = 0.5

    /// One block: a rectangle in unit space plus how round its corners are, as a fraction of its
    /// shorter side. `1.0` gives a capsule.
    struct Part: Hashable {
        var x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat
        var round: CGFloat = 0.45
    }

    private func shape(_ part: Part, in w: CGFloat, h: CGFloat, x originX: CGFloat) -> some Shape {
        let rect = CGRect(x: originX + part.x * w, y: part.y * h,
                          width: part.w * w, height: part.h * h)
        let radius = min(rect.width, rect.height) * part.round
        return RoundedRectangle(cornerRadius: radius).path(in: rect)
            .asShape()
    }

    /// The body underneath the regions: head, torso, limbs. Drawn in the inset surface so the figure
    /// still reads as a body on a week with no training at all.
    ///
    /// PROPORTIONS: the box is twice as tall as it is wide, so ONE X-UNIT IS HALF AS BIG AS ONE
    /// Y-UNIT. Every width here is therefore about double what it would be in a square grid. Writing
    /// these numbers as if the grid were square is what produced the first version: a stick figure
    /// with its arms buried inside its torso. The figure is laid out on the standard 7.5-head canon —
    /// head 0.12 of the height, shoulders about two head-widths across.
    static let silhouette: [Part] = [
        Part(x: 0.415, y: 0.020, w: 0.170, h: 0.120, round: 1.0),   // head
        Part(x: 0.465, y: 0.130, w: 0.070, h: 0.050, round: 0.40),  // neck
        Part(x: 0.318, y: 0.165, w: 0.364, h: 0.245, round: 0.22),  // torso
        Part(x: 0.325, y: 0.395, w: 0.350, h: 0.085, round: 0.30),  // pelvis
        Part(x: 0.196, y: 0.185, w: 0.100, h: 0.260, round: 1.0),   // left arm
        Part(x: 0.704, y: 0.185, w: 0.100, h: 0.260, round: 1.0),   // right arm
        Part(x: 0.335, y: 0.455, w: 0.155, h: 0.375, round: 0.40),  // left leg
        Part(x: 0.510, y: 0.455, w: 0.155, h: 0.375, round: 0.40),  // right leg
        Part(x: 0.332, y: 0.812, w: 0.146, h: 0.048, round: 0.45),  // left foot
        Part(x: 0.522, y: 0.812, w: 0.146, h: 0.048, round: 0.45),  // right foot
    ]

    static func parts(for face: Face) -> [(region: Region, part: Part)] {
        switch face {
        case .front: return front
        case .back:  return back
        }
    }

    private static let front: [(region: Region, part: Part)] = [
        (.neck,       Part(x: 0.467, y: 0.135, w: 0.066, h: 0.045, round: 0.40)),
        (.traps,      Part(x: 0.372, y: 0.172, w: 0.090, h: 0.030, round: 0.40)),
        (.traps,      Part(x: 0.538, y: 0.172, w: 0.090, h: 0.030, round: 0.40)),
        (.shoulders,  Part(x: 0.222, y: 0.178, w: 0.120, h: 0.078, round: 0.60)),
        (.shoulders,  Part(x: 0.658, y: 0.178, w: 0.120, h: 0.078, round: 0.60)),
        (.chest,      Part(x: 0.335, y: 0.207, w: 0.155, h: 0.075, round: 0.30)),
        (.chest,      Part(x: 0.510, y: 0.207, w: 0.155, h: 0.075, round: 0.30)),
        (.abdominals, Part(x: 0.395, y: 0.292, w: 0.210, h: 0.100, round: 0.20)),
        (.biceps,     Part(x: 0.206, y: 0.240, w: 0.084, h: 0.096, round: 1.0)),
        (.biceps,     Part(x: 0.710, y: 0.240, w: 0.084, h: 0.096, round: 1.0)),
        (.forearms,   Part(x: 0.209, y: 0.348, w: 0.078, h: 0.096, round: 1.0)),
        (.forearms,   Part(x: 0.713, y: 0.348, w: 0.078, h: 0.096, round: 1.0)),
        (.abductors,  Part(x: 0.312, y: 0.420, w: 0.046, h: 0.072, round: 1.0)),
        (.abductors,  Part(x: 0.642, y: 0.420, w: 0.046, h: 0.072, round: 1.0)),
        (.quadriceps, Part(x: 0.345, y: 0.478, w: 0.098, h: 0.158, round: 0.50)),
        (.quadriceps, Part(x: 0.557, y: 0.478, w: 0.098, h: 0.158, round: 0.50)),
        (.adductors,  Part(x: 0.449, y: 0.492, w: 0.043, h: 0.120, round: 0.60)),
        (.adductors,  Part(x: 0.508, y: 0.492, w: 0.043, h: 0.120, round: 0.60)),
        (.calves,     Part(x: 0.356, y: 0.672, w: 0.100, h: 0.135, round: 0.50)),
        (.calves,     Part(x: 0.544, y: 0.672, w: 0.100, h: 0.135, round: 0.50)),
    ]

    private static let back: [(region: Region, part: Part)] = [
        (.neck,       Part(x: 0.467, y: 0.135, w: 0.066, h: 0.045, round: 0.40)),
        (.traps,      Part(x: 0.377, y: 0.168, w: 0.246, h: 0.072, round: 0.30)),
        (.shoulders,  Part(x: 0.245, y: 0.180, w: 0.115, h: 0.075, round: 0.60)),
        (.shoulders,  Part(x: 0.640, y: 0.180, w: 0.115, h: 0.075, round: 0.60)),
        (.upperBack,  Part(x: 0.377, y: 0.245, w: 0.246, h: 0.058, round: 0.20)),
        (.lats,       Part(x: 0.316, y: 0.248, w: 0.086, h: 0.112, round: 0.40)),
        (.lats,       Part(x: 0.598, y: 0.248, w: 0.086, h: 0.112, round: 0.40)),
        (.lowerBack,  Part(x: 0.400, y: 0.310, w: 0.200, h: 0.082, round: 0.20)),
        (.triceps,    Part(x: 0.206, y: 0.240, w: 0.084, h: 0.096, round: 1.0)),
        (.triceps,    Part(x: 0.710, y: 0.240, w: 0.084, h: 0.096, round: 1.0)),
        (.forearms,   Part(x: 0.209, y: 0.348, w: 0.078, h: 0.096, round: 1.0)),
        (.forearms,   Part(x: 0.713, y: 0.348, w: 0.078, h: 0.096, round: 1.0)),
        (.abductors,  Part(x: 0.312, y: 0.415, w: 0.046, h: 0.072, round: 1.0)),
        (.abductors,  Part(x: 0.642, y: 0.415, w: 0.046, h: 0.072, round: 1.0)),
        (.glutes,     Part(x: 0.343, y: 0.405, w: 0.148, h: 0.082, round: 0.40)),
        (.glutes,     Part(x: 0.509, y: 0.405, w: 0.148, h: 0.082, round: 0.40)),
        (.hamstrings, Part(x: 0.347, y: 0.500, w: 0.140, h: 0.135, round: 0.50)),
        (.hamstrings, Part(x: 0.513, y: 0.500, w: 0.140, h: 0.135, round: 0.50)),
        (.calves,     Part(x: 0.356, y: 0.672, w: 0.100, h: 0.135, round: 0.50)),
        (.calves,     Part(x: 0.544, y: 0.672, w: 0.100, h: 0.135, round: 0.50)),
    ]
}

/// Wraps a ready-made `Path` so the geometry above can be written once and used for fill, stroke and
/// hit-testing without rebuilding it three times.
private struct PathShape: Shape {
    let path: Path
    func path(in rect: CGRect) -> Path { path }
}

private extension Path {
    func asShape() -> some Shape { PathShape(path: self) }
}
