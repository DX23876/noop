//
//  Bundle+MuscleMap.swift
//  MuscleMap
//
//  Created by Melih Colpan on 2026-02-10.
//  Copyright © 2026 Melih Colpan. All rights reserved.
//  Licensed under the MIT License.
//

import Foundation

extension Bundle {
    /// Resolves one MuscleMap resource in a caller-selected locale. Passing no locale keeps the
    /// normal system/app-language behaviour; the explicit form also makes localization tests
    /// deterministic on machines whose preferred language is not English.
    func muscleMapLocalizedString(_ key: String, locale: Locale? = nil) -> String {
        guard let locale else {
            return localizedString(forKey: key, value: nil, table: nil)
        }

        let identifiers = [locale.identifier, locale.language.languageCode?.identifier].compactMap { $0 }
        for identifier in identifiers {
            guard let path = path(forResource: identifier, ofType: "lproj"),
                  let localizedBundle = Bundle(path: path) else { continue }
            return localizedBundle.localizedString(forKey: key, value: nil, table: nil)
        }
        return localizedString(forKey: key, value: nil, table: nil)
    }
}

#if !SWIFT_PACKAGE
private class BundleFinder {}

extension Bundle {
    /// Resolves the MuscleMap resource bundle for CocoaPods.
    static let module: Bundle = {
        let bundleName = "MuscleMap"
        let candidates = [
            Bundle(for: BundleFinder.self).resourceURL,
            Bundle.main.resourceURL,
        ]
        for candidate in candidates {
            let bundlePath = candidate?.appendingPathComponent(bundleName + ".bundle")
            if let bundle = bundlePath.flatMap(Bundle.init(url:)) {
                return bundle
            }
        }
        return Bundle(for: BundleFinder.self)
    }()
}
#endif
