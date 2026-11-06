import Foundation

/// 系统层面的指针默认值：恢复时用来写回「原本不存在」的属性。
public enum SystemDefaults {
    /// `com.apple.mouse.scaling`（`HIDMouseAcceleration` 的全局来源）。
    /// 未设置时用 Apple 的 `0.6875`（`HIDPointerAcceleration` 出厂值）。
    public static var mouseAcceleration: Double {
        let value = CFPreferencesCopyValue("com.apple.mouse.scaling" as CFString,
                                          kCFPreferencesAnyApplication,
                                          kCFPreferencesCurrentUser,
                                          kCFPreferencesAnyHost) as? NSNumber
        return value?.doubleValue ?? 0.6875
    }

    /// 驱动自带的参数化曲线（`HIDAccelCurves`），读取失败时返回 nil。
    public static var accelCurves: [[String: Int32]]? {
        let url = URL(fileURLWithPath:
            "/System/Library/Extensions/IOHIDFamily.kext/Contents/PlugIns"
                + "/IOHIDEventDriver.kext/Contents/Info.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = (try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil)) as? [String: Any],
              let personalities = plist["IOKitPersonalities"] as? [String: Any],
              let keyboard = personalities["HID Keyboard Driver"] as? [String: Any],
              let curves = keyboard["HIDAccelCurves"] as? [[String: Any]]
        else {
            return nil
        }
        return curves.compactMap { entry in
            let converted = entry.compactMapValues { ($0 as? NSNumber)?.int32Value }
            return converted.count == entry.count ? converted : nil
        }
    }
}
