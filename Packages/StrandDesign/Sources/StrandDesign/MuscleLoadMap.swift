import SwiftUI

// MARK: - Muscle load map
//
// An anatomical body diagram whose regions are shaded by how much WORK each one has taken in a recent
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
// reported as text beside the map rather than folded into the same channel — fusing "how much" and
// "how long ago" into one number is precisely the step that turns two measurements into one model.
//
// ## Where the artwork comes from
//
// `Resources/MuscleMapPaths.json` holds the outlines, derived from the MIT-licensed SVG body of
// react-native-body-highlighter (Copyright (c) 2022 ELABBASSI Hicham). The full licence text ships
// beside it as `Resources/MuscleMapPaths.LICENSE` and must stay there: MIT permits this use and
// requires the notice to travel with the copy.
//
// The SVG paths were converted offline into absolute cubic Béziers, normalised to a 0...1 unit box
// (front viewBox `0 0 724 1448`, back `724 0 724 1448`). Converting rather than shipping a runtime SVG
// parser is deliberate: two thirds of the source paths use elliptical arcs, and arc-to-Bézier is the
// kind of maths that fails quietly and slightly. Doing it once, offline, against a renderer you can
// look at is safer than doing it on every launch.
//
// ## Regions are muscle GROUPS, not muscle heads
//
// The artwork is anatomical, but the regions stop at the granularity the data has. Hevy attributes a
// set to ONE primary group per exercise, so there is no honest way to shade the long head of the
// triceps differently from the lateral head — and a diagram that drew them apart would be claiming a
// resolution the log cannot support.
//
// The component itself is pure presentation: it takes intensities the caller has already computed and
// fills shapes. It knows nothing about sets, days, or muscles-as-data.

public struct MuscleLoadMap: View {

    /// A shadeable region of the diagram.
    ///
    /// Named for the body rather than for any one data source, so the design package stays free of
    /// `WhoopStore` (it has no dependencies, deliberately) and the app does the mapping. The set is
    /// exactly what the artwork can draw: there is no `lats` or `abductors` shape, so those map onto
    /// `upperBack` and `glutes` at the call site, where the reasoning belongs.
    public enum Region: String, Sendable, CaseIterable, Codable {
        case neck, traps, shoulders, chest, biceps, triceps, forearms, abdominals
        case upperBack, lowerBack
        case glutes, quadriceps, hamstrings, calves, adductors
    }

    /// Which way the body faces. A muscle only visible from behind simply is not drawn on the front —
    /// never drawn dim, which would read as "trained a little".
    public enum Face: String, Sendable, CaseIterable, Codable {
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
    /// The tint filled regions take. Passed in so the map inherits whatever domain it sits in rather
    /// than hardcoding a colour.
    public var tint: Color
    /// Called when a region is tapped, so the caller can point its list at the matching row.
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
            // The figure keeps its 1:2 aspect whatever box it is given, so it never stretches: it is
            // centred in the available space instead.
            let h = geo.size.height
            let w = min(geo.size.width, h * Self.aspect)
            let originX = (geo.size.width - w) / 2
            let art = MuscleMapArt.shared[face]

            ZStack(alignment: .topLeading) {
                ForEach(Array(art.silhouette.enumerated()), id: \.offset) { _, outline in
                    PathShape(path: outline.path(width: w, height: h, originX: originX))
                        .fill(StrandPalette.surfaceInset)
                }
                // Indexed, NOT keyed by region: a paired muscle contributes several outlines with the
                // same region, and keying by region made SwiftUI treat them as one item and draw a
                // half-shaded body — every left side present, every right side missing.
                ForEach(Array(art.regions.enumerated()), id: \.offset) { _, item in
                    let shape = PathShape(path: item.outline.path(width: w, height: h, originX: originX))
                    shape
                        .fill(fill(for: item.region))
                        .overlay(shape.stroke(StrandPalette.hairline, lineWidth: 0.5))
                        .contentShape(shape)
                        .onTapGesture { onSelect?(item.region) }
                        .accessibilityElement()
                        .accessibilityLabel(Text(label(item.region)))
                        .accessibilityValue(Text(accessibilityValue(item.region)))
                }
            }
        }
        .aspectRatio(Self.aspect, contentMode: .fit)
    }

    /// Width divided by height, from the source artwork's 724 × 1448 viewBox.
    static let aspect: CGFloat = 0.5

    /// Untouched regions take the inset surface rather than a faint tint. A barely-tinted shape would
    /// read as "a little work", and zero is not a little.
    private func fill(for region: Region) -> Color {
        let value = intensity[region] ?? 0
        guard value > 0 else { return StrandPalette.surfaceInset }
        // Floor the opacity well clear of the background so one set is visibly more than none, then
        // scale the rest linearly. No curve: a curve would imply a dose-response shape this component
        // has no business asserting.
        return tint.opacity(0.28 + 0.72 * min(1, value))
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
        case .lowerBack:   return String(localized: "Lower back", bundle: .module)
        case .glutes:      return String(localized: "Glutes", bundle: .module)
        case .quadriceps:  return String(localized: "Quadriceps", bundle: .module)
        case .hamstrings:  return String(localized: "Hamstrings", bundle: .module)
        case .calves:      return String(localized: "Calves", bundle: .module)
        case .adductors:   return String(localized: "Adductors", bundle: .module)
        }
    }
}

// MARK: - The artwork

/// One closed outline in unit space, stored as the compact command string the converter emits.
///
/// Only `M`, `C` and `Z` occur: every line, quadratic and elliptical arc in the source was turned into
/// cubics offline. A reader of three commands is short enough to be obviously correct, which is the
/// point — the alternative was an SVG arc implementation running on the device.
struct MuscleOutline {
    let commands: String

    func path(width w: CGFloat, height h: CGFloat, originX: CGFloat) -> Path {
        var path = Path()
        var rest = commands[commands.startIndex...]

        func point(_ n: [CGFloat], _ i: Int) -> CGPoint {
            CGPoint(x: originX + n[i] * w, y: n[i + 1] * h)
        }

        while let index = rest.firstIndex(where: { $0 == "M" || $0 == "C" || $0 == "Z" }) {
            let letter = rest[index]
            let tail = rest[rest.index(after: index)...]
            let next = tail.firstIndex(where: { $0 == "M" || $0 == "C" || $0 == "Z" }) ?? tail.endIndex
            let numbers: [CGFloat] = tail[..<next].split(separator: " ").compactMap {
                guard let d = Double($0) else { return nil }
                return CGFloat(d)
            }
            switch letter {
            case "M" where numbers.count >= 2:
                path.move(to: point(numbers, 0))
            case "C" where numbers.count >= 6:
                path.addCurve(to: point(numbers, 4),
                              control1: point(numbers, 0), control2: point(numbers, 2))
            case "Z":
                path.closeSubpath()
            default:
                break
            }
            rest = tail[next...]
        }
        return path
    }
}

/// Loads and caches the converted artwork.
///
/// Decoded once per process. A missing or unreadable resource yields an EMPTY figure rather than a
/// fallback drawing: a body that silently lost half its muscles because a file did not load would be
/// read as "you have not trained those".
final class MuscleMapArt {
    struct Side {
        var silhouette: [MuscleOutline] = []
        var regions: [(region: MuscleLoadMap.Region, outline: MuscleOutline)] = []
    }

    static let shared = MuscleMapArt()

    private let sides: [MuscleLoadMap.Face: Side]

    subscript(face: MuscleLoadMap.Face) -> Side { sides[face] ?? Side() }

    private init() {
        struct Document: Decodable {
            struct Side: Decodable {
                let silhouette: [String]
                let regions: [String: [String]]
            }
            let front: Side
            let back: Side
        }
        guard let url = Bundle.module.url(forResource: "MuscleMapPaths", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let doc = try? JSONDecoder().decode(Document.self, from: data) else {
            sides = [:]
            return
        }
        func build(_ input: Document.Side) -> Side {
            var side = Side(silhouette: input.silhouette.map { MuscleOutline(commands: $0) })
            // Sorted by region name so the draw order — and therefore which outline sits on top where
            // two overlap — is identical on every launch.
            for name in input.regions.keys.sorted() {
                guard let region = MuscleLoadMap.Region(rawValue: name) else { continue }
                for d in input.regions[name] ?? [] {
                    side.regions.append((region, MuscleOutline(commands: d)))
                }
            }
            return side
        }
        sides = [.front: build(doc.front), .back: build(doc.back)]
    }
}

/// Wraps a ready-made `Path` so a shape can be built once and used for fill, stroke and hit-testing.
private struct PathShape: Shape {
    let path: Path
    func path(in rect: CGRect) -> Path { path }
}
