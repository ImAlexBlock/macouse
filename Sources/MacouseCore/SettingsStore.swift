import Foundation

/// `UserDefaults` 持久化。
public final class SettingsStore {
    private enum Key {
        static let accelerationEnabled = "accelerationEnabled"
        static let speedPosition = "speedPosition"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.accelerationEnabled: true,
            Key.speedPosition: 6,
        ])
    }

    public var settings: WindowsPointerSettings {
        get {
            WindowsPointerSettings(
                accelerationEnabled: defaults.bool(forKey: Key.accelerationEnabled),
                speedPosition: defaults.integer(forKey: Key.speedPosition)
            )
        }
        set {
            defaults.set(newValue.accelerationEnabled, forKey: Key.accelerationEnabled)
            defaults.set(WindowsPointerModel.clampPosition(newValue.speedPosition),
                         forKey: Key.speedPosition)
        }
    }
}
