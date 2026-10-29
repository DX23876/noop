import XCTest
@testable import Strand

/// #2430: the personal daytime-stress lens reaches Stress detail and both Apple Today layouts.
///
/// The baseline math has package tests; this pins the app-target wiring that can otherwise compile
/// while silently omitting the preference at one call site.
final class StressPersonalBaselineSurfaceTests: XCTestCase {
    private func source(_ path: String, file: StaticString = #filePath) throws -> String {
        let testFile = URL(fileURLWithPath: "\(file)")
        let root = testFile.deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testDetailAndTodayUseTheSameSelectedMode() throws {
        let detail = try source("Strand/Screens/StressView.swift")
        let producer = try source("Strand/Data/StressDayCurve.swift")
        let today = try source("Strand/Screens/TodayView.swift")
        let liquidToday = try source("Strand/Liquid/LiquidTodayView.swift")

        XCTAssertNotNil(detail.range(
            of: #"DaytimeStressMode\.selected\([\s\S]*?personalBaseline:\s*PuffinExperiment\.stressPersonalBaselineEnabled"#,
            options: .regularExpression
        ))
        XCTAssertNotNil(detail.range(
            of: #"DaytimeStress\.analyze\([\s\S]*?mode:\s*mode,"#,
            options: .regularExpression
        ))
        // The producer's reads and lens live in the shared `DaytimeStressDay` (also the Android core's), and the
        // producer scores with the mode it selected for the requested lens.
        let shared = try source("Strand/Data/DaytimeStressMode.swift")
        XCTAssertTrue(shared.contains("let mode = await DaytimeStressMode.selected("))
        XCTAssertTrue(shared.contains("personalBaseline: personalBaseline)"))
        XCTAssertTrue(producer.contains("DaytimeStressDay.inputs(source: repo, now: now, calendar: calendar,"))
        XCTAssertTrue(producer.contains("tzOffsetSeconds: inputs.tzOffsetSeconds, mode: inputs.mode,"))
        for body in [today, liquidToday] {
            XCTAssertTrue(body.contains(
                "personalBaseline: PuffinExperiment.stressPersonalBaselineEnabled"
            ))
        }
        // A slot per lens, not one slot that compares the lens: comparing made the two surfaces evict
        // each other on every alternation, so the fingerprint gate never held with the toggle on.
        XCTAssertTrue(producer.contains("memos[personalBaseline]"))
    }

    func testWidgetPublisherRetainsTheCheapDefaultMode() throws {
        let widget = try source("StrandiOS/Widgets/WidgetPublish.swift")
        XCTAssertFalse(widget.contains("personalBaseline:"))
    }
}
