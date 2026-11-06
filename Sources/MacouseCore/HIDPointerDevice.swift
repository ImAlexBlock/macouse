import CryptoKit
import Foundation
import IOKit
import MacouseSPI

/// 驱动读取的指针加速属性名（Apple `IOHIDParameter.h` / `IOHIDPrivateKeys.h`）。
public enum PointerPropertyKey {
    public static let resolution = "HIDPointerResolution"
    public static let mouseAcceleration = "HIDMouseAcceleration"
    public static let pointerAcceleration = "HIDPointerAcceleration"
    public static let accelerationType = "HIDPointerAccelerationType"
    public static let useLinearScaling = "HIDUseLinearScalingMouseAcceleration"
    public static let accelerationTable = "HIDPointerAccelerationTable"
    public static let accelCurves = "HIDAccelCurves"
    public static let reportRate = "HIDPointerReportRate"
    public static let serviceFilterDebug = "IOHIDServiceFilterDebug"

    /// `HIDPointerAccelerationType` 的取值。
    public static let mouseAccelerationType = "HIDMouseAcceleration"

    /// 本 App 会改写的全部属性；恢复时逐键写回。
    public static let managed = [
        resolution,
        mouseAcceleration,
        accelerationType,
        useLinearScaling,
        accelerationTable,
        accelCurves,
    ]
}

/// 一个 HID 指针服务。
public struct HIDPointerDevice: Sendable {
    public let registryID: UInt64
    public let product: String
    public let isBuiltIn: Bool
    public let hasParametricCurves: Bool
    public let reportRate: Int?
    public let conformsToMouse: Bool
    public let conformsToPointer: Bool
    public let hasMouseAccelerationProperty: Bool

    /// 服务自己发布的 `HIDPointerAccelerationType`；非 "HIDMouseAcceleration" 时
    /// 驱动会在每次重新解析后覆盖客户端的写入。
    public let accelerationType: String?

    /// 驱动会为指针服务声明 `HIDMouseAcceleration`，这是比 usage 声明更可靠的识别依据。
    public var isPointerService: Bool {
        conformsToMouse || conformsToPointer
    }
}

/// 属性读写的定点与文本工具。
public enum PointerPropertyValue {
    public static func fixed(_ value: Double) -> CFNumber {
        NSNumber(value: AccelerationTable.fixed(value))
    }

    public static func number(_ value: CFTypeRef) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        return number.doubleValue
    }

    /// `HIDMouseAcceleration` 这类 16.16 定点数按 double 打印。
    public static func describe(_ value: CFTypeRef?) -> String {
        guard let value else { return "<absent>" }
        if CFGetTypeID(value) == CFDataGetTypeID(), let data = value as? Data {
            return "data(\(data.count) bytes, sha256 \(data.sha256.prefix(16)))"
        }
        if let number = value as? NSNumber {
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            let raw = number.int64Value
            return "\(raw) (fixed \(Double(raw) / 65536))"
        }
        if let string = value as? String { return string }
        if let array = value as? [Any] { return "array(\(array.count))" }
        return "\(value)"
    }
}

extension Data {
    public var sha256: String {
        SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined()
    }
}
