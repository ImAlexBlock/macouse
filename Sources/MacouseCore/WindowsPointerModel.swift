import Foundation

/// 用户可见的设置：加速开关 + Windows 速度档位。
public struct WindowsPointerSettings: Equatable, Sendable {
    public var accelerationEnabled: Bool
    public var speedPosition: Int

    public init(accelerationEnabled: Bool = true, speedPosition: Int = 6) {
        self.accelerationEnabled = accelerationEnabled
        self.speedPosition = WindowsPointerModel.clampPosition(speedPosition)
    }

    /// Windows 第 6 档 = 1.0×，其余档位按 `MouseSensitivity / 10`。
    public var multiplier: Double {
        WindowsPointerModel.multiplier(forPosition: speedPosition)
    }
}

/// Windows 指针模型：档位倍率、默认加速曲线、以及与 Apple HID 驱动之间的单位换算。
///
/// 单位换算的两条事实来自 Apple `IOHIDFamily` 源码（`IOHIDPointerScrollFilter.cpp`、
/// `IOHIDAccelerationAlgorithm.cpp`）：
///
/// 1. 表式加速：驱动把表内的 x 乘 `resolution / FRAME_RATE`、y 乘 `kCursorScale`，
///    其中 `FRAME_RATE = 67`（常量，与设备轮询率无关），`kCursorScale = 96/67`。
///    线段斜率即 px/count：`px/count = (ΔY/ΔX) · kCursorScale · FRAME_RATE / resolution`。
/// 2. 参数化加速：驱动输入 `x = velocity · rate / resolution`，输出再乘 `kCursorScale`；
///    其中 `rate = HIDPointerReportRate`（设备报告率），`velocity` 为每报告 counts。
///
/// 驱动速度轴上的 `velocity` 是「每个报告周期的 counts」。Windows 默认曲线按 125 Hz
/// 报告率定义速度，因此两个模型之间差一个 `resolution / WindowsReportRate` 的换算。
public enum WindowsPointerModel {
    /// Windows 指针速度档位 1…11（`SPI_SETMOUSESPEED` 取值 1…20，控制面板只暴露 1…11）。
    public static let positions = 1...11

    /// 第 1…11 档对应的倍率；第 6 档 = 1.0。
    public static let speedMultipliers: [Double] = [
        0.1, 0.2, 0.4, 0.6, 0.8, 1.0, 1.2, 1.4, 1.6, 1.8, 2.0,
    ]

    /// Windows 10/11「提高指针精确度」默认曲线（`SmoothMouseXCurve` / `SmoothMouseYCurve`）。
    public static let windowsCurvePoints: [(x: Double, y: Double)] = [
        (0.0, 0.0),
        (0.4300079345703125, 1.0702667236328125),
        (1.25, 4.140625),
        (3.8600006103515625, 18.984375),
        (40.0, 443.75),
    ]

    /// Windows 曲线按 125 Hz 报告率定义速度轴（counts per report）。
    public static let windowsReportRate = 125.0

    /// Apple `kCursorScale`。
    public static let cursorScale = 96.0 / 67.0

    /// Apple `FRAME_RATE`：表式加速的固定换算频率。
    public static let frameRate = 67.0

    /// 写入 `HIDPointerResolution` 的分辨率（与 Apple `kDefaultPointerResolutionFixed` 一致）。
    public static let pointerResolution = 400.0

    /// 曲线原点斜率。Windows 用它把曲线归一成「慢速 1:1」，因此加速开启时慢速位移
    /// 与加速关闭时相同，速度越快增益越大（末段 4.72×）。
    public static let originSlope =
        windowsCurvePoints[1].y / windowsCurvePoints[1].x

    /// 参数化曲线系数（a, b, c, d），满足 `f(x) = a·x + (b·x)² + (c·x)³ + (d·x)⁴`。
    ///
    /// 由 Windows 曲线的三锚点 `f(0.43) / f(1.25) / f(3.86)` 与末段斜率 `f'(3.86)` 解出，
    /// 因此在锚点上与 Windows 曲线一致（误差 < 1e-13），超过 3.86 后按末段切线线性外推，
    /// 与 Windows 的末段外推一致。
    public static let curveCoefficients: [Double] = [
        1.6596621951424324,
        1.5276182150661544,
        -1.0039070717110155,
        0.6345710017982031,
    ]

    /// `f(x) = a·x + (b·x)² + (c·x)³ + (d·x)⁴`，与驱动的参数化公式一致。
    public static func curveValue(_ x: Double) -> Double {
        curveCoefficients.enumerated().reduce(0) { partial, item in
            partial + pow(item.element * x, Double(item.offset + 1))
        }
    }

    /// `f'(x)`：用于校验参数化解与 Windows 末段斜率。
    public static func curveSlope(_ x: Double) -> Double {
        let c = curveCoefficients
        return c[0]
            + 2 * c[1] * c[1] * x
            + 3 * pow(c[2], 3) * x * x
            + 4 * pow(c[3], 4) * x * x * x
    }

    public static func clampPosition(_ position: Int) -> Int {
        min(max(position, positions.lowerBound), positions.upperBound)
    }

    public static func multiplier(forPosition position: Int) -> Double {
        speedMultipliers[clampPosition(position) - positions.lowerBound]
    }

    /// 表式路径：表内 x 的换算系数，使驱动速度轴等于 Windows 的 125 Hz 速度轴。
    public static let tableXScale = frameRate / pointerResolution

    /// 表式路径：表内 y 的换算系数（每个倍率单位），使线段斜率等于 Windows 归一化增益。
    public static let tableYScale = 1.0 / (originSlope * cursorScale)
}
