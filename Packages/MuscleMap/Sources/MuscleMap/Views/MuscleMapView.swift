//
//  MuscleMapView.swift
//  MuscleMap
//
//  Created by Melih Colpan on 2026-02-10.
//  Copyright © 2026 Melih Colpan. All rights reserved.
//  Licensed under the MIT License.
//

#if canImport(UIKit)
import UIKit
import SwiftUI

/// A UIKit view that wraps ``BodyView`` for use in UIKit-based projects.
///
/// `MuscleMapView` embeds a SwiftUI ``BodyView`` inside a `UIHostingController`,
/// exposing all configuration through mutable properties and convenience methods.
///
/// ```swift
/// let muscleMap = MuscleMapView(gender: .male, side: .front)
/// muscleMap.highlight(.chest, color: .systemRed)
/// muscleMap.onMuscleSelected = { muscle, side in
///     print("Tapped \(muscle.displayName)")
/// }
/// view.addSubview(muscleMap)
/// ```
public class MuscleMapView: UIView {

    // MARK: - Configuration Properties

    /// The body gender model to display.
    public var gender: BodyGender {
        didSet { updateBodyView() }
    }

    /// Which side of the body to display.
    public var side: BodySide {
        didSet { updateBodyView() }
    }

    /// The visual style of the body view.
    public var style: BodyViewStyle {
        didSet { updateBodyView() }
    }

    /// Currently highlighted muscles and their visual configuration.
    public var highlights: [Muscle: MuscleHighlight] = [:] {
        didSet { updateBodyView() }
    }

    /// The set of muscles marked as selected.
    public var selectedMuscles: Set<Muscle> = [] {
        didSet { updateBodyView() }
    }

    /// Whether to show sub-group muscles (e.g. upperChest, lowerChest).
    public var showSubGroups: Bool = false {
        didSet { updateBodyView() }
    }

    /// Whether highlight changes are animated.
    public var isAnimated: Bool = false {
        didSet { updateBodyView() }
    }

    /// Duration of highlight animations, in seconds.
    public var animationDuration: Double = 0.3 {
        didSet { updateBodyView() }
    }

    /// Whether pulse animation is enabled on selected muscles.
    public var isPulseEnabled: Bool = false {
        didSet { updateBodyView() }
    }

    /// Speed of the pulse animation.
    public var pulseSpeed: Double = 1.5 {
        didSet { updateBodyView() }
    }

    /// Opacity range for the pulse animation.
    public var pulseRange: ClosedRange<Double> = 0.6...1.0 {
        didSet { updateBodyView() }
    }

    /// Whether pinch-to-zoom is enabled.
    public var isZoomEnabled: Bool = false {
        didSet { updateBodyView() }
    }

    /// Minimum zoom scale when zoom is enabled.
    public var minZoomScale: CGFloat = 1.0 {
        didSet { updateBodyView() }
    }

    /// Maximum zoom scale when zoom is enabled.
    public var maxZoomScale: CGFloat = 4.0 {
        didSet { updateBodyView() }
    }

    // MARK: - Callbacks

    /// Called when a muscle is tapped.
    public var onMuscleSelected: ((Muscle, MuscleSide) -> Void)?

    /// Called when a muscle is long-pressed.
    public var onMuscleLongPressed: ((Muscle, MuscleSide) -> Void)?

    /// Called when a muscle is dragged over.
    public var onMuscleDragged: ((Muscle, MuscleSide) -> Void)?

    /// Called when drag gesture ends.
    public var onMuscleDragEnded: (() -> Void)?

    /// Duration required for long-press recognition, in seconds.
    public var longPressDuration: Double = 0.5

    // MARK: - Private

    private var hostingController: UIHostingController<AnyView>?

    // MARK: - Initializers

    /// Creates a new muscle map view.
    /// - Parameters:
    ///   - gender: Body gender model (default: `.male`).
    ///   - side: Front or back view (default: `.front`).
    ///   - style: Visual style configuration (default: `.default`).
    public init(
        gender: BodyGender = .male,
        side: BodySide = .front,
        style: BodyViewStyle = .default
    ) {
        self.gender = gender
        self.side = side
        self.style = style
        super.init(frame: .zero)
        setupHostingController()
    }

    public required init?(coder: NSCoder) {
        self.gender = .male
        self.side = .front
        self.style = .default
        super.init(coder: coder)
        setupHostingController()
    }

    // MARK: - Convenience Methods

    /// Highlights a muscle with a UIKit color.
    /// - Parameters:
    ///   - muscle: The muscle to highlight.
    ///   - color: The UIKit color.
    ///   - opacity: Opacity of the highlight (0.0–1.0).
    public func highlight(_ muscle: Muscle, color: UIColor, opacity: Double = 1.0) {
        highlights[muscle] = MuscleHighlight(
            muscle: muscle,
            color: Color(color),
            opacity: opacity
        )
    }

    /// Highlights multiple muscles with the same UIKit color.
    /// - Parameters:
    ///   - muscles: The muscles to highlight.
    ///   - color: The UIKit color.
    ///   - opacity: Opacity of the highlight (0.0–1.0).
    public func highlight(_ muscles: [Muscle], color: UIColor, opacity: Double = 1.0) {
        var updated = highlights
        for muscle in muscles {
            updated[muscle] = MuscleHighlight(
                muscle: muscle,
                color: Color(color),
                opacity: opacity
            )
        }
        highlights = updated
    }

    /// Applies intensity-based highlighting using an integer scale (0–4).
    /// - Parameters:
    ///   - data: Dictionary mapping muscles to intensity levels (0–4).
    ///   - colorScale: The heatmap color scale to use.
    public func setIntensities(_ data: [Muscle: Int], colorScale: HeatmapColorScale = .workout) {
        var updated: [Muscle: MuscleHighlight] = [:]
        for (muscle, level) in data {
            let normalizedIntensity = Double(min(max(level, 0), 4)) / 4.0
            let color = colorScale.color(for: normalizedIntensity)
            updated[muscle] = MuscleHighlight(muscle: muscle, color: color, opacity: 1.0)
        }
        highlights = updated
    }

    /// Applies heatmap data using ``MuscleIntensity`` values.
    /// - Parameters:
    ///   - data: Array of muscle intensity entries.
    ///   - colorScale: The heatmap color scale to use.
    public func setHeatmap(_ data: [MuscleIntensity], colorScale: HeatmapColorScale = .workout) {
        var updated: [Muscle: MuscleHighlight] = [:]
        for entry in data {
            let color = entry.color ?? colorScale.color(for: entry.intensity)
            updated[entry.muscle] = MuscleHighlight(muscle: entry.muscle, color: color, opacity: 1.0)
        }
        highlights = updated
    }

    /// Removes all muscle highlights.
    public func clearHighlights() {
        highlights = [:]
    }

    // MARK: - Layout

    public override func layoutSubviews() {
        super.layoutSubviews()
        hostingController?.view.frame = bounds
    }

    // MARK: - Private

    private func setupHostingController() {
        let bodyView = buildBodyView()
        let hosting = UIHostingController(rootView: AnyView(bodyView))
        hosting.view.backgroundColor = .clear
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting.view)

        NSLayoutConstraint.activate([
            hosting.view.topAnchor.constraint(equalTo: topAnchor),
            hosting.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        self.hostingController = hosting
    }

    private func updateBodyView() {
        let bodyView = buildBodyView()
        hostingController?.rootView = AnyView(bodyView)
    }

    private func buildBodyView() -> some View {
        var view = BodyView(gender: gender, side: side, style: style)

        // Apply highlights
        for (_, highlight) in highlights {
            view = view.highlight(highlight.muscle, color: highlight.color, opacity: highlight.opacity)
        }

        // Apply selections
        if !selectedMuscles.isEmpty {
            view = view.selected(selectedMuscles)
        }

        // Sub-groups
        if showSubGroups {
            view = view.showSubGroups()
        }

        // Animation
        if isAnimated {
            view = view.animated(duration: animationDuration)
        }

        // Pulse
        if isPulseEnabled {
            view = view.pulseSelected(speed: pulseSpeed, range: pulseRange)
        }

        // Zoom
        if isZoomEnabled {
            view = view.zoomable(minScale: minZoomScale, maxScale: maxZoomScale)
        }

        // Callbacks
        if let onMuscleSelected {
            view = view.onMuscleSelected(onMuscleSelected)
        }

        if let onMuscleLongPressed {
            view = view.onMuscleLongPressed(duration: longPressDuration, action: onMuscleLongPressed)
        }

        if let onMuscleDragged {
            view = view.onMuscleDragged(onMuscleDragged, onEnded: onMuscleDragEnded ?? {})
        }

        return view
    }
}

#endif
