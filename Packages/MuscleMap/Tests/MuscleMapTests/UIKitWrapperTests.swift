import XCTest
@testable import MuscleMap

#if canImport(UIKit)
import UIKit

final class UIKitWrapperTests: XCTestCase {

    // MARK: - MuscleMapView Tests

    func testMuscleMapViewDefaultInit() {
        let view = MuscleMapView()
        XCTAssertEqual(view.gender, .male)
        XCTAssertEqual(view.side, .front)
        XCTAssertTrue(view.highlights.isEmpty)
        XCTAssertTrue(view.selectedMuscles.isEmpty)
    }

    func testMuscleMapViewCustomInit() {
        let view = MuscleMapView(gender: .female, side: .back, style: .minimal)
        XCTAssertEqual(view.gender, .female)
        XCTAssertEqual(view.side, .back)
    }

    func testMuscleMapViewHighlight() {
        let view = MuscleMapView()
        view.highlight(.chest, color: .red)
        XCTAssertNotNil(view.highlights[.chest])
        XCTAssertEqual(view.highlights[.chest]?.muscle, .chest)
        XCTAssertEqual(view.highlights[.chest]?.opacity, 1.0)
    }

    func testMuscleMapViewHighlightMultiple() {
        let view = MuscleMapView()
        view.highlight([.chest, .biceps, .abs], color: .blue, opacity: 0.8)
        XCTAssertEqual(view.highlights.count, 3)
        XCTAssertNotNil(view.highlights[.chest])
        XCTAssertNotNil(view.highlights[.biceps])
        XCTAssertNotNil(view.highlights[.abs])
        XCTAssertEqual(view.highlights[.chest]?.opacity, 0.8)
    }

    func testMuscleMapViewSetIntensities() {
        let view = MuscleMapView()
        view.setIntensities([.chest: 4, .biceps: 2, .abs: 0])
        XCTAssertEqual(view.highlights.count, 3)
        XCTAssertNotNil(view.highlights[.chest])
        XCTAssertNotNil(view.highlights[.biceps])
        XCTAssertNotNil(view.highlights[.abs])
    }

    func testMuscleMapViewSetHeatmap() {
        let view = MuscleMapView()
        let data = [
            MuscleIntensity(muscle: .chest, intensity: 0.8),
            MuscleIntensity(muscle: .biceps, intensity: 0.5),
        ]
        view.setHeatmap(data)
        XCTAssertEqual(view.highlights.count, 2)
        XCTAssertNotNil(view.highlights[.chest])
        XCTAssertNotNil(view.highlights[.biceps])
    }

    func testMuscleMapViewClearHighlights() {
        let view = MuscleMapView()
        view.highlight(.chest, color: .red)
        view.highlight(.biceps, color: .blue)
        XCTAssertEqual(view.highlights.count, 2)

        view.clearHighlights()
        XCTAssertTrue(view.highlights.isEmpty)
    }

    func testMuscleMapViewPropertyDefaults() {
        let view = MuscleMapView()
        XCTAssertFalse(view.showSubGroups)
        XCTAssertFalse(view.isAnimated)
        XCTAssertEqual(view.animationDuration, 0.3)
        XCTAssertFalse(view.isPulseEnabled)
        XCTAssertEqual(view.pulseSpeed, 1.5)
        XCTAssertEqual(view.pulseRange, 0.6...1.0)
        XCTAssertFalse(view.isZoomEnabled)
        XCTAssertEqual(view.minZoomScale, 1.0)
        XCTAssertEqual(view.maxZoomScale, 4.0)
        XCTAssertEqual(view.longPressDuration, 0.5)
    }

    func testMuscleMapViewCallbacksNilByDefault() {
        let view = MuscleMapView()
        XCTAssertNil(view.onMuscleSelected)
        XCTAssertNil(view.onMuscleLongPressed)
        XCTAssertNil(view.onMuscleDragged)
        XCTAssertNil(view.onMuscleDragEnded)
    }

    func testMuscleMapViewPropertyChanges() {
        let view = MuscleMapView()
        view.gender = .female
        view.side = .back
        view.showSubGroups = true
        view.isAnimated = true
        view.isPulseEnabled = true
        view.isZoomEnabled = true

        XCTAssertEqual(view.gender, .female)
        XCTAssertEqual(view.side, .back)
        XCTAssertTrue(view.showSubGroups)
        XCTAssertTrue(view.isAnimated)
        XCTAssertTrue(view.isPulseEnabled)
        XCTAssertTrue(view.isZoomEnabled)
    }

    func testMuscleMapViewSelectedMuscles() {
        let view = MuscleMapView()
        view.selectedMuscles = [.chest, .biceps]
        XCTAssertEqual(view.selectedMuscles.count, 2)
        XCTAssertTrue(view.selectedMuscles.contains(.chest))
        XCTAssertTrue(view.selectedMuscles.contains(.biceps))
    }

    // MARK: - HeatmapLegendUIView Tests

    func testHeatmapLegendUIViewInit() {
        let legend = HeatmapLegendUIView(colorScale: .workout)
        XCTAssertEqual(legend.interpolation, .linear)
        XCTAssertEqual(legend.orientation, .horizontal)
        XCTAssertEqual(legend.barThickness, 16)
        XCTAssertNil(legend.labelMin)
        XCTAssertNil(legend.labelMax)
    }

    func testHeatmapLegendUIViewCustomInit() {
        let legend = HeatmapLegendUIView(
            colorScale: .thermal,
            interpolation: .easeInOut,
            orientation: .vertical,
            barThickness: 24,
            labelMin: "None",
            labelMax: "Max"
        )
        XCTAssertEqual(legend.interpolation, .easeInOut)
        XCTAssertEqual(legend.orientation, .vertical)
        XCTAssertEqual(legend.barThickness, 24)
        XCTAssertEqual(legend.labelMin, "None")
        XCTAssertEqual(legend.labelMax, "Max")
    }

    func testHeatmapLegendUIViewPropertyChanges() {
        let legend = HeatmapLegendUIView(colorScale: .workout)
        legend.orientation = .vertical
        legend.barThickness = 20
        legend.labelMin = "Low"
        legend.labelMax = "High"

        XCTAssertEqual(legend.orientation, .vertical)
        XCTAssertEqual(legend.barThickness, 20)
        XCTAssertEqual(legend.labelMin, "Low")
        XCTAssertEqual(legend.labelMax, "High")
    }
}

#endif
