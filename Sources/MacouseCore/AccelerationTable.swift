import Foundation

/// `HIDPointerAccelerationTable` 的二进制编码，以及与 Windows 曲线的互转。
///
/// 编码布局来自 Apple `IOHIDAccelerationTable.hpp` / `.cpp`：
///
/// ```
/// scale      uint32  大端      (16.16 定点；表式解析不使用该字段)
/// signature  uint32  原生读取   (Apple 常量 0x30303240，因此字节序为 40 32 30 30)
/// count      uint16  大端
/// entry[]            count 个：
///   accel  uint32  大端 (16.16 定点)
///   count  uint16  大端
///   point[]        count 个：x uint32 大端 (16.16), y uint32 大端 (16.16)
/// ```
///
/// signature 是唯一按原生字节序读取的字段（`ACCEL_TABLE::signature()` 直接返回结构体字段），
/// 其余字段都经过 `OSReadBigInt32` / `OSReadBigInt16`。两者混用，写错会让整张表被驱动拒绝，
/// 指针退回无加速状态而不报错。
public enum AccelerationTable {
    /// Apple 默认表签名（`APPLE_ACCELERATION_DEFAULT_TABLE_SIGNATURE`）。
    public static let defaultSignature: UInt32 = 0x3030_3240

    /// Apple 多点触控表签名（`APPLE_ACCELERATION_MT_TABLE_SIGNATURE`）。
    public static let mtSignature: UInt32 = 0x2a42_5355

    /// 驱动在表表达式里使用的 `scale` 字段值 1.0。
    public static let scale: UInt32 = 0x0001_0000

    /// Apple 内置默认表（`IOHIDPointerScrollFilter.cpp` 的 `defaultAccelTable[]`，102 字节）。
    /// 用于恢复「属性原本不存在」时的驱动默认行为。
    public static let defaultAccelTable = Data([
        0x00, 0x00, 0x80, 0x00,
        0x40, 0x32, 0x30, 0x30, 0x00, 0x02, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00,
        0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00,
        0x00, 0x09, 0x00, 0x00, 0x71, 0x3B, 0x00, 0x00,
        0x60, 0x00, 0x00, 0x04, 0x4E, 0xC5, 0x00, 0x10,
        0x80, 0x00, 0x00, 0x0C, 0x00, 0x00, 0x00, 0x5F,
        0x00, 0x00, 0x00, 0x16, 0xEC, 0x4F, 0x00, 0x8B,
        0x00, 0x00, 0x00, 0x1D, 0x3B, 0x14, 0x00, 0x94,
        0x80, 0x00, 0x00, 0x22, 0x76, 0x27, 0x00, 0x96,
        0x00, 0x00, 0x00, 0x24, 0x62, 0x76, 0x00, 0x96,
        0x00, 0x00, 0x00, 0x26, 0x00, 0x00, 0x00, 0x96,
        0x00, 0x00, 0x00, 0x28, 0x00, 0x00, 0x00, 0x96,
        0x00, 0x00,
    ])

    /// 编码一张加速表。`entries` 每项为 `(acceleration, points)`。
    public static func encode(entries: [(acceleration: Double, points: [(x: Double, y: Double)])])
        -> Data
    {
        var data = Data()
        data.append(bigEndian: scale)
        data.append(littleEndian: defaultSignature)
        data.append(bigEndian: UInt16(entries.count))
        for entry in entries {
            data.append(bigEndian: UInt32(bitPattern: fixed(entry.acceleration)))
            data.append(bigEndian: UInt16(entry.points.count))
            for point in entry.points {
                data.append(bigEndian: UInt32(bitPattern: fixed(point.x)))
                data.append(bigEndian: UInt32(bitPattern: fixed(point.y)))
            }
        }
        return data
    }

    /// 表式路径的加速表：x 轴换算到驱动速度轴，y 轴按倍率缩放。
    ///
    /// 两个 entry 写成同一组点，取值范围 0…3，使 `HIDMouseAcceleration`（这里写 1.5）
    /// 永远落在两个 entry 之间做插值，而不会触发「高于最高档」的额外 y 缩放。
    public static func windowsTable(multiplier: Double) -> Data {
        let points = windowsCurvePoints(multiplier: multiplier)
        return encode(entries: [
            (acceleration: 0.0, points: points),
            (acceleration: 3.0, points: points),
        ])
    }

    /// Windows 曲线换算成表内定点坐标。
    public static func windowsCurvePoints(multiplier: Double) -> [(x: Double, y: Double)] {
        WindowsPointerModel.windowsCurvePoints.map { point in
            (x: point.x * WindowsPointerModel.tableXScale,
             y: point.y * WindowsPointerModel.tableYScale * multiplier)
        }
    }

    /// 参数化路径的曲线字典（`HIDAccelCurves`）。
    ///
    /// 驱动按 `x = velocity · rate / resolution` 取横轴，输出再乘 `kCursorScale`，
    /// 因此系数要做三件事（`f = Σ (cᵢ·x)^i`，系数在幂内，所以每项只能按 λ^(1/i) 缩放）：
    /// 1. 横轴代入 `x · resolution / windowsReportRate`，把驱动横轴换成 Windows 的
    ///    125 Hz 速度轴；系数乘 `resolution / windowsReportRate`。
    /// 2. 输出乘 `λ = multiplier · windowsReportRate / (originSlope · kCursorScale · rate)`，
    ///    使增益等于 Windows 的归一化增益。
    /// 3. 上两项合并即 `cᵢ = aᵢ · axis · λ^(1/(i+1))`，让每项贡献一次幂的倍率。
    public static func parametricCurves(multiplier: Double, reportRate: Int,
                                        resolution: Double = WindowsPointerModel.pointerResolution)
        -> [[String: Int32]]
    {
        let lambda = multiplier * WindowsPointerModel.windowsReportRate
            / (WindowsPointerModel.originSlope * WindowsPointerModel.cursorScale
                * Double(reportRate))
        let axis = resolution / WindowsPointerModel.windowsReportRate
        let coefficients = WindowsPointerModel.curveCoefficients.enumerated().map { index, value in
            value * axis * pow(lambda, 1.0 / Double(index + 1))
        }
        let tangent = WindowsPointerModel.windowsCurvePoints[3].x / axis
        return [[
            "HIDAccelIndex": fixed(123),
            "HIDAccelGainLinear": fixed(coefficients[0]),
            "HIDAccelGainParabolic": fixed(coefficients[1]),
            "HIDAccelGainCubic": fixed(coefficients[2]),
            "HIDAccelGainQuartic": fixed(coefficients[3]),
            "HIDAccelTangentSpeedLinear": fixed(tangent),
            "HIDAccelTangentSpeedParabolicRoot": 0,
        ]]
    }

    /// 16.16 定点。
    public static func fixed(_ value: Double) -> Int32 {
        let scaled = (value * 65536).rounded()
        return Int32(max(min(scaled, 2_147_483_647), -2_147_483_648))
    }

    public static func double(_ fixed: Int32) -> Double {
        Double(fixed) / 65536
    }
}

private extension Data {
    mutating func append(bigEndian value: UInt32) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    mutating func append(bigEndian value: UInt16) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    mutating func append(littleEndian value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
