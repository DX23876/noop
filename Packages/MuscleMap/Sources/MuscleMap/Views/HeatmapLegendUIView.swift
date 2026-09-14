//
//  HeatmapLegendUIView.swift
//  MuscleMap
//
//  Created by Melih Colpan on 2026-02-10.
//  Copyright © 2026 Melih Colpan. All rights reserved.
//  Licensed under the MIT License.
//

#if canImport(UIKit)
import UIKit
import SwiftUI

/// A UIKit view that wraps ``HeatmapLegendView`` for use in UIKit-based projects.
///
/// ```swift
/// let legend = HeatmapLegendUIView(colorScale: .workout)
/// legend.orientation = .horizontal
/// view.addSubview(legend)
/// ```
public class HeatmapLegendUIView: UIView {

    // MARK: - Configuration Properties

    /// The color scale displayed in the legend.
    public var colorScale: HeatmapColorScale {
        didSet { updateLegendView() }
    }

    /// Interpolation curve applied to the color bar.
    public var interpolation: ColorInterpolation {
        didSet { updateLegendView() }
    }

    /// Orientation of the legend bar.
    public var orientation: NSLayoutConstraint.Axis {
        didSet { updateLegendView() }
    }

    /// Thickness of the color bar (height if horizontal, width if vertical).
    public var barThickness: CGFloat {
        didSet { updateLegendView() }
    }

    /// Label for the low end of the scale. Uses localized default if `nil`.
    public var labelMin: String? {
        didSet { updateLegendView() }
    }

    /// Label for the high end of the scale. Uses localized default if `nil`.
    public var labelMax: String? {
        didSet { updateLegendView() }
    }

    // MARK: - Private

    private var hostingController: UIHostingController<AnyView>?

    // MARK: - Initializers

    /// Creates a new heatmap legend view.
    /// - Parameters:
    ///   - colorScale: The color scale to display.
    ///   - interpolation: Interpolation curve (default: `.linear`).
    ///   - orientation: Layout orientation (default: `.horizontal`).
    ///   - barThickness: Thickness of the color bar (default: `16`).
    ///   - labelMin: Low-end label (default: localized "Low").
    ///   - labelMax: High-end label (default: localized "High").
    public init(
        colorScale: HeatmapColorScale,
        interpolation: ColorInterpolation = .linear,
        orientation: NSLayoutConstraint.Axis = .horizontal,
        barThickness: CGFloat = 16,
        labelMin: String? = nil,
        labelMax: String? = nil
    ) {
        self.colorScale = colorScale
        self.interpolation = interpolation
        self.orientation = orientation
        self.barThickness = barThickness
        self.labelMin = labelMin
        self.labelMax = labelMax
        super.init(frame: .zero)
        setupHostingController()
    }

    public required init?(coder: NSCoder) {
        self.colorScale = .workout
        self.interpolation = .linear
        self.orientation = .horizontal
        self.barThickness = 16
        self.labelMin = nil
        self.labelMax = nil
        super.init(coder: coder)
        setupHostingController()
    }

    // MARK: - Layout

    public override func layoutSubviews() {
        super.layoutSubviews()
        hostingController?.view.frame = bounds
    }

    // MARK: - Private

    private func setupHostingController() {
        let legendView = buildLegendView()
        let hosting = UIHostingController(rootView: AnyView(legendView))
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

    private func updateLegendView() {
        let legendView = buildLegendView()
        hostingController?.rootView = AnyView(legendView)
    }

    private func buildLegendView() -> some View {
        let swiftUIOrientation: Axis = orientation == .vertical ? .vertical : .horizontal
        return HeatmapLegendView(
            colorScale: colorScale,
            interpolation: interpolation,
            orientation: swiftUIOrientation,
            barThickness: barThickness,
            labelMin: labelMin,
            labelMax: labelMax
        )
    }
}

#endif
