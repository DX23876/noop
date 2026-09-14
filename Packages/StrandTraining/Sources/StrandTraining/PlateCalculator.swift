import Foundation

public struct PlateLoading: Equatable, Sendable {
    public let platesPerSideKg: [Double]
    public let achievableTotalKg: Double
    public let remainderKg: Double

    public init(platesPerSideKg: [Double], achievableTotalKg: Double, remainderKg: Double) {
        self.platesPerSideKg = platesPerSideKg
        self.achievableTotalKg = achievableTotalKg
        self.remainderKg = remainderKg
    }
}

public enum PlateCalculator {
    public static func loading(totalKg: Double, barKg: Double,
                               availablePairsKg: [Double] = [25, 20, 15, 10, 5, 2.5, 1.25]) -> PlateLoading? {
        guard totalKg.isFinite, barKg.isFinite, totalKg >= barKg, barKg >= 0 else { return nil }
        var side = (totalKg - barKg) / 2
        var plates: [Double] = []
        for plate in availablePairsKg.filter({ $0.isFinite && $0 > 0 }).sorted(by: >) {
            while side + 0.000_001 >= plate {
                plates.append(plate)
                side -= plate
            }
        }
        let loaded = totalKg - side * 2
        return .init(platesPerSideKg: plates, achievableTotalKg: loaded,
                     remainderKg: max(0, totalKg - loaded))
    }
}
