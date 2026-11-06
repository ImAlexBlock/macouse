import XCTest
@testable import MacouseCore

/// 按 Apple `ACCEL_TABLE` / `ACCEL_TABLE_ENTRY` 的解析方式解码（`IOHIDAccelerationTable.cpp`）：
/// `scale`、`count`、`accel`、点坐标都用大端读取，`signature` 按原生字节序读取。
private struct DecodedTable {
    struct Entry {
        let acceleration: Double
        let points: [(x: Double, y: Double)]
    }

    let scale: Double
    let signature: UInt32
    let entries: [Entry]
    let byteCount: Int
    let consumed: Int

    init(_ data: Data) {
        let bytes = [UInt8](data)
        byteCount = bytes.count
        func bigInt32(_ offset: Int) -> Int32 {
            var value = Int32(bytes[offset]) << 24
            value |= Int32(bytes[offset + 1]) << 16
            value |= Int32(bytes[offset + 2]) << 8
            value |= Int32(bytes[offset + 3])
            return value
        }
        func bigUInt16(_ offset: Int) -> UInt16 {
            UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
        }
        scale = Double(bigInt32(0)) / 65536
        signature = UInt32(bytes[4]) | UInt32(bytes[5]) << 8 | UInt32(bytes[6]) << 16
            | UInt32(bytes[7]) << 24
        var count = Int(bigUInt16(8))
        var offset = 10
        var decoded: [Entry] = []
        while count > 0 {
            count -= 1
            let acceleration = Double(bigInt32(offset)) / 65536
            let points = Int(bigUInt16(offset + 4))
            offset += 6
            var list: [(x: Double, y: Double)] = []
            for _ in 0..<points {
                list.append((Double(bigInt32(offset)) / 65536, Double(bigInt32(offset + 4)) / 65536))
                offset += 8
            }
            decoded.append(Entry(acceleration: acceleration, points: list))
        }
        entries = decoded
        consumed = offset
    }
}

/// 按 Apple `IOHIDPointerAccelerator::accelerate` + `IOHIDTableAcceleration` 的算式求 px/count。
private enum DriverMath {
    /// 表路径：驱动把 x 乘 `resolution / FRAME_RATE`、y 乘 `kCursorScale`，线段斜率即 px/count。
    static func tableSegments(_ data: Data) -> [(gain: Double, breakpoint: Double)] {
        let table = DecodedTable(data)
        let resolution = WindowsPointerModel.pointerResolution
        let rate = WindowsPointerModel.frameRate
        let scale = WindowsPointerModel.cursorScale
        let points = table.entries[0].points
        var segments: [(gain: Double, breakpoint: Double)] = []
        var previous = (x: 0.0, y: 0.0)
        for point in points {
            let x = point.x * resolution / rate
            let y = point.y * scale
            let slope = x == previous.x ? 0 : (y - previous.y) / (x - previous.x)
            segments.append((slope, x))
            previous = (x, y)
        }
        return segments
    }

    /// 参数化路径：`x = velocity · rate / resolution`，`px/count = f(x) · kCursorScale / velocity`。
    static func parametricGain(atWindowsSpeed speed: Double, curves: [[String: Int32]],
                               reportRate: Int) -> Double
    {
        let resolution = WindowsPointerModel.pointerResolution
        let resolutionScale = resolution / WindowsPointerModel.windowsReportRate
        let x = speed * WindowsPointerModel.windowsReportRate / resolution
        let coefficients = ["HIDAccelGainLinear", "HIDAccelGainParabolic",
                            "HIDAccelGainCubic", "HIDAccelGainQuartic"]
            .map { Double(curves[0][$0] ?? 0) / 65536 }
        let value = coefficients.enumerated().reduce(0.0) { partial, item in
            partial + pow(item.element * x, Double(item.offset + 1))
        }
        let velocity = x * resolution / Double(reportRate)
        _ = resolutionScale
        return value * WindowsPointerModel.cursorScale / velocity
    }

    /// Windows 归一化增益（曲线弦斜率除以原点斜率）。
    static func windowsGain(atSpeed speed: Double) -> Double {
        WindowsPointerModel.curveValue(speed) / (WindowsPointerModel.originSlope * speed)
    }
}

final class AccelerationTableTests: XCTestCase {
    func testEncodingLayout() {
        let data = AccelerationTable.windowsTable(multiplier: 1)
        let table = DecodedTable(data)
        XCTAssertEqual(table.byteCount, 102)
        XCTAssertEqual(table.consumed, 102, "编码必须恰好被驱动消费完")
        XCTAssertEqual(table.signature, AccelerationTable.defaultSignature)
        XCTAssertEqual(table.scale, 1.0, accuracy: 1e-12)
        XCTAssertEqual(table.entries.count, 2)
        XCTAssertEqual(table.entries[0].acceleration, 0, accuracy: 1e-12)
        XCTAssertEqual(table.entries[1].acceleration, 3.0, accuracy: 1e-12)
        XCTAssertEqual(table.entries[0].points.count, 5)
        // 两个 entry 必须完全相同，否则驱动会按插值算出另一条曲线。
        for index in 0..<table.entries[0].points.count {
            XCTAssertEqual(table.entries[1].points[index].x,
                           table.entries[0].points[index].x, accuracy: 1e-12)
            XCTAssertEqual(table.entries[1].points[index].y,
                           table.entries[0].points[index].y, accuracy: 1e-12)
        }
    }

    func testSignatureBytesAreNativeOrdered() {
        let data = AccelerationTable.windowsTable(multiplier: 1)
        let bytes = [UInt8](data.prefix(12))
        XCTAssertEqual(bytes[0..<4], [0x00, 0x01, 0x00, 0x00], "scale 大端")
        XCTAssertEqual(bytes[4..<8], [0x40, 0x32, 0x30, 0x30], "signature 原生字节序")
        XCTAssertEqual(bytes[8..<10], [0x00, 0x02], "count 大端")
    }

    func testPointsAreScaledWindowsCurve() {
        let multiplier = 1.4
        let data = AccelerationTable.windowsTable(multiplier: multiplier)
        let table = DecodedTable(data)
        for (index, expected) in WindowsPointerModel.windowsCurvePoints.enumerated() {
            let point = table.entries[0].points[index]
            XCTAssertEqual(point.x, expected.x * WindowsPointerModel.tableXScale, accuracy: 2e-5)
            XCTAssertEqual(point.y,
                           expected.y * WindowsPointerModel.tableYScale * multiplier,
                           accuracy: 2e-5)
        }
    }

    func testDriverGainsMatchWindowsCurve() {
        let windowsSlopes = zip(WindowsPointerModel.windowsCurvePoints.dropFirst(),
                                WindowsPointerModel.windowsCurvePoints)
            .map { next, previous in (next.y - previous.y) / (next.x - previous.x) }
        for multiplier in [0.1, 1.0, 2.0] {
            let segments = DriverMath.tableSegments(
                AccelerationTable.windowsTable(multiplier: multiplier))
            let gains = segments.dropFirst().map(\.gain)
            XCTAssertEqual(gains.count, windowsSlopes.count)
            for (gain, slope) in zip(gains, windowsSlopes) {
                let expected = slope / WindowsPointerModel.originSlope * multiplier
                XCTAssertEqual(gain, expected, accuracy: 1e-3)
            }
            // 断点必须落在 Windows 的速度坐标上。
            for (segment, point) in zip(segments.dropFirst(),
                                        WindowsPointerModel.windowsCurvePoints.dropFirst()) {
                XCTAssertEqual(segment.breakpoint, point.x, accuracy: 2e-4)
            }
        }
    }

    func testDefaultTableMatchesAppleConstants() {
        let table = DecodedTable(AccelerationTable.defaultAccelTable)
        XCTAssertEqual(table.byteCount, 102)
        XCTAssertEqual(table.consumed, 102)
        XCTAssertEqual(table.signature, 0x3030_3240)
        XCTAssertEqual(table.scale, 0.5, accuracy: 1e-12)
        XCTAssertEqual(table.entries.count, 2)
        XCTAssertEqual(table.entries[0].points.count, 1)
        XCTAssertEqual(table.entries[1].points.count, 9)
    }
}

final class ParametricCurveTests: XCTestCase {
    func testCurveMatchesWindowsAnchors() {
        for point in WindowsPointerModel.windowsCurvePoints.dropFirst().dropLast() {
            XCTAssertEqual(WindowsPointerModel.curveValue(point.x), point.y, accuracy: 1e-9)
        }
        let slope = (443.75 - 18.984375) / (40.0 - 3.8600006103515625)
        XCTAssertEqual(WindowsPointerModel.curveSlope(3.8600006103515625), slope, accuracy: 1e-9)
    }

    func testCurveIsLinearInMultiplier() {
        let reportRate = 125
        for multiplier in [0.5, 1.0, 2.0] {
            let curves = AccelerationTable.parametricCurves(multiplier: multiplier,
                                                            reportRate: reportRate)
            for speed in [0.4300079345703125, 1.25, 3.86] {
                let gain = DriverMath.parametricGain(atWindowsSpeed: speed, curves: curves,
                                                     reportRate: reportRate)
                XCTAssertEqual(gain, DriverMath.windowsGain(atSpeed: speed) * multiplier,
                               accuracy: 2e-3)
            }
        }
    }

    func testCurveIsReportRateIndependent() {
        let speed = 3.86
        let reference = DriverMath.parametricGain(
            atWindowsSpeed: speed,
            curves: AccelerationTable.parametricCurves(multiplier: 1, reportRate: 125),
            reportRate: 125)
        for reportRate in [1000, 8000] {
            let gain = DriverMath.parametricGain(
                atWindowsSpeed: speed,
                curves: AccelerationTable.parametricCurves(multiplier: 1, reportRate: reportRate),
                reportRate: reportRate)
            XCTAssertEqual(gain, reference, accuracy: 1e-3)
        }
    }

    func testCurveEncodesIndexAndTangent() {
        let curves = AccelerationTable.parametricCurves(multiplier: 1, reportRate: 125)
        XCTAssertEqual(curves.count, 1)
        let curve = curves[0]
        XCTAssertEqual(curve["HIDAccelIndex"], 123 << 16)
        XCTAssertEqual(curve["HIDAccelTangentSpeedParabolicRoot"], 0)
        XCTAssertEqual(Double(curve["HIDAccelTangentSpeedLinear"] ?? 0) / 65536,
                       3.8600006103515625 / 3.2, accuracy: 1e-5)
        XCTAssertEqual(Set(curve.keys), [
            "HIDAccelIndex", "HIDAccelGainLinear", "HIDAccelGainParabolic",
            "HIDAccelGainCubic", "HIDAccelGainQuartic",
            "HIDAccelTangentSpeedLinear", "HIDAccelTangentSpeedParabolicRoot",
        ])
    }

    func testFixedEncodingRoundsAndClamps() {
        XCTAssertEqual(AccelerationTable.fixed(1.0), 65536)
        XCTAssertEqual(AccelerationTable.fixed(0.5), 32768)
        XCTAssertEqual(AccelerationTable.fixed(-2.0), -131072)
        XCTAssertEqual(AccelerationTable.double(98304), 1.5)
        XCTAssertEqual(AccelerationTable.fixed(1e9), Int32.max)
    }
}
