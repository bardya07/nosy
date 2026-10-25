import Foundation

enum AIFeatures {
    static let storageKey = "aiFeaturesEnabled"

    static func enabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: storageKey)
    }
}
