#if DEBUG
import Foundation

// MARK: - DEBUG-only hero fixture (Liquid Today organic rings)
//
// The redesign's acceptance asks for the real renderer at fixed values (nil, 20, 50, 80, 90, 94, 100)
// on real iPhone aspect ratios. Seeded data cannot hit a chosen value, so this pins the three hero rings
// when the process is launched with `--demo-hero <charge>,<effort>,<rest>`: each on the stored 0–100
// scale, `-` for "no data". Effort is still formatted through the user's Effort scale.
//
//     xcrun simctl launch booted <bundle id> --demo-hero 94,40,-
//
// Gating: the whole file is `#if DEBUG` (stripped from Release), and nothing changes without the flag.
// It overrides only what the hero DRAWS; no stored value, route or analysis is touched.

struct DemoHeroFixture: Equatable {
    let charge: Double?
    let effort: Double?
    let rest: Double?
}

enum DemoHeroHarness {
    static let active: DemoHeroFixture? = parse(CommandLine.arguments)

    /// Pure parse of the launch arguments; nil unless `--demo-hero` carries three comma-separated values.
    static func parse(_ args: [String]) -> DemoHeroFixture? {
        guard let flag = args.firstIndex(of: "--demo-hero"), args.index(after: flag) < args.endIndex else {
            return nil
        }
        let parts = args[args.index(after: flag)].split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 3 else { return nil }
        func value(_ raw: String) -> Double? {
            guard let number = Double(raw), number.isFinite else { return nil }
            return min(max(number, 0), 100)
        }
        return DemoHeroFixture(charge: value(parts[0]), effort: value(parts[1]), rest: value(parts[2]))
    }
}
#endif
