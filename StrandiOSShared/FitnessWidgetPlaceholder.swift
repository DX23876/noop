import Foundation

extension FitnessWidgetSnapshot {
    /// The gallery preview: two plausible weeks for every widget, never shown as the wearer's data.
    public static var placeholder: FitnessWidgetSnapshot {
        let keys = (0..<14).map { String(format: "2026-01-%02d", $0 + 1) }
        let letters = ["M", "T", "W", "T", "F", "S", "S", "M", "T", "W", "T", "F", "S", "S"]
        let charge: [Double?] = [62, 71, 48, 55, 80, 77, 66, 58, 73, 69, 41, 64, 82, 74]
        let effort: [Double?] = [45, 62, 30, 71, 55, 20, 38, 66, 49, 58, 74, 33, 41, 52]
        return FitnessWidgetSnapshot(
            days: keys, dayLetters: letters, charge: charge, effort: effort,
            effortTexts: effort.map { $0.map { "\(Int($0))" } },
            hrv: [58, 62, 55, 60, 66, 64, 59, 57, 63, 61, 52, 58, 67, 64],
            rhr: [54, 53, 56, 55, 52, 52, 54, 55, 53, 53, 57, 55, 51, 52],
            sleepHours: [7.1, 6.8, 7.6, 6.2, 7.9, 8.3, 7.0, 6.9, 7.4, 7.2, 5.9, 7.1, 8.0, 7.3],
            steps: [8_200, 11_400, 6_300, 9_800, 12_100, 15_600, 7_400, 8_900, 10_300, 9_100, 5_800, 9_600, 13_200, 6_450],
            hrvUsual: .init(low: 56, high: 65), rhrUsual: .init(low: 52, high: 56),
            sleep: .init(day: keys[13], totalMin: 438, needMin: 470, deepMin: 92, remMin: 104, lightMin: 242,
                         efficiency: 91),
            stepsGoal: 10_000,
            weight: .init(unit: "kg", readings: [
                .init(day: "2026-01-02", value: 82.4), .init(day: "2026-01-05", value: 82.1),
                .init(day: "2026-01-08", value: 81.8), .init(day: "2026-01-11", value: 81.9),
                .init(day: "2026-01-14", value: 81.3),
            ], change: -1.1),
            workouts: .init(count: 3, minutes: 145, trainedDays: [true, false, true, false, true, false, false],
                            weekLetters: ["M", "T", "W", "T", "F", "S", "S"], todayIndex: 4,
                            lastName: "Running", lastSymbol: "figure.run", lastDay: keys[13], lastMinutes: 42),
            activeDays: (0..<84).map { $0 % 3 != 1 ? true : ($0 % 7 == 0 ? nil : false) },
            vitals: [
                .init(id: "spo2", name: "Blood Oxygen", symbol: "drop", value: 96, text: "96 %",
                      usual: .init(low: 95, high: 98)),
                .init(id: "resp", name: "Respiratory Rate", symbol: "lungs", value: 14.6, text: "14.6 rpm",
                      usual: .init(low: 13.9, high: 15.2)),
                .init(id: "skinTemp", name: "Skin Temperature", symbol: "thermometer", value: 0.2, text: "+0.2 °C",
                      usual: .init(low: -0.3, high: 0.4)),
            ],
            updated: Date())
    }
}
