//
//  BodyAccessibilityOverlay.swift
//  MuscleMap
//
//  Created by Melih Colpan on 2026-02-10.
//  Copyright © 2026 Melih Colpan. All rights reserved.
//  Licensed under the MIT License.
//

import SwiftUI

/// An invisible overlay that exposes each visible muscle as an accessibility element for VoiceOver.
struct BodyAccessibilityOverlay: View {

    let gender: BodyGender
    let side: BodySide
    let highlights: [Muscle: MuscleHighlight]
    let style: BodyViewStyle
    let selectedMuscles: Set<Muscle>
    let size: CGSize
    let onMuscleSelected: ((Muscle, MuscleSide) -> Void)?
    let onMuscleLongPressed: ((Muscle, MuscleSide) -> Void)?
    var hideSubGroups: Bool = true

    var body: some View {
        let renderer = BodyRenderer(
            gender: gender,
            side: side,
            highlights: highlights,
            style: style,
            selectedMuscles: selectedMuscles,
            hideSubGroups: hideSubGroups
        )
        let muscles = visibleMuscles(renderer: renderer)

        ZStack {
            ForEach(muscles, id: \.muscle) { item in
                accessibilityElement(for: item)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(NSLocalizedString("accessibility.bodyMap", bundle: .module, comment: ""))
    }

    @ViewBuilder
    private func accessibilityElement(for item: MuscleAccessibilityItem) -> some View {
        let isSelected = selectedMuscles.contains(item.muscle)
        let valueKey = isSelected ? "accessibility.selected" : "accessibility.notSelected"
        let hintKey = onMuscleLongPressed != nil ? "accessibility.hint.longPress" : "accessibility.hint.tap"
        let traits: AccessibilityTraits = isSelected ? [.isButton, .isSelected] : [.isButton]

        Color.clear
            .frame(width: item.rect.width, height: item.rect.height)
            .position(x: item.rect.midX, y: item.rect.midY)
            .accessibilityElement()
            .accessibilityLabel(item.muscle.displayName)
            .accessibilityValue(NSLocalizedString(valueKey, bundle: .module, comment: ""))
            .accessibilityHint(NSLocalizedString(hintKey, bundle: .module, comment: ""))
            .accessibilityAddTraits(traits)
            .accessibilityAction(.default) {
                onMuscleSelected?(item.muscle, .both)
            }
            .accessibilityAction(named: Text(NSLocalizedString("accessibility.hint.longPress", bundle: .module, comment: ""))) {
                onMuscleLongPressed?(item.muscle, .both)
            }
    }

    // MARK: - Private

    /// Returns visible muscles sorted top-to-bottom for natural VoiceOver traversal.
    /// Excludes cosmetic parts (e.g., head).
    private func visibleMuscles(renderer: BodyRenderer) -> [MuscleAccessibilityItem] {
        let bodyParts = BodyPathProvider.paths(gender: gender, side: side)
        var seen = Set<Muscle>()
        var items: [MuscleAccessibilityItem] = []

        for bodyPart in bodyParts {
            guard let muscle = bodyPart.slug.muscle,
                  !muscle.isCosmeticPart,
                  !seen.contains(muscle) else { continue }
            if hideSubGroups && muscle.isSubGroup && !muscle.isAlwaysVisibleSubGroup { continue }
            seen.insert(muscle)

            if let rect = renderer.boundingRect(for: muscle, in: size), !rect.isEmpty {
                items.append(MuscleAccessibilityItem(muscle: muscle, rect: rect))
            }
        }

        // Sort top-to-bottom (by minY) for anatomical VoiceOver traversal
        items.sort { $0.rect.minY < $1.rect.minY }
        return items
    }
}

/// A muscle with its bounding rect for accessibility layout.
fileprivate struct MuscleAccessibilityItem {
    let muscle: Muscle
    let rect: CGRect
}
