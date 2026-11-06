import Foundation
import IOKit
import MacouseSPI

/// 单个服务的应用结果。
public struct ServiceApplyResult: Sendable {
    public enum Path: String, Sendable {
        case linear
        case table
        case parametric
        case unsupported
    }

    public let registryID: UInt64
    public let product: String
    public var path: Path
    public var verified: Bool
    public var lines: [String]
}

/// 把 Windows 指针设置写进 HID 服务的加速属性。
///
/// 两条路径（依据 Apple `IOHIDPointerScrollFilter.cpp::createPointerAlgorithm`）：
///
/// - 服务没有 `HIDAccelCurves` → 表路径：写 `HIDPointerAccelerationTable`，
///   `HIDUseLinearScalingMouseAcceleration = 0`，`HIDMouseAcceleration = 1.5`
///   （落在表内 0…3 两档之间插值）。
/// - 服务已有 `HIDAccelCurves` → 参数化路径：写 `HIDAccelCurves`，
///   `HIDMouseAcceleration = 123`（曲线 index 也是 123），`HIDUseLinearScalingMouseAcceleration = 0`。
///
/// 驱动只在 `HIDPointerAccelerationType == "HIDMouseAcceleration"` 时才读这些值，
/// 所以每次应用都先写类型键。
public final class PointerSettingsApplier {
    public private(set) var lastResults: [ServiceApplyResult] = []
    public private(set) var lastSettings: WindowsPointerSettings?

    private let manager: PointerServiceManager
    private let snapshotStore: SnapshotStore
    private var originals: [UInt64: [String: CFTypeRef]] = [:]
    private var isApplying = false

    public init(manager: PointerServiceManager, snapshotStore: SnapshotStore = SnapshotStore()) {
        self.manager = manager
        self.snapshotStore = snapshotStore
    }

    public var hasSnapshot: Bool {
        !originals.isEmpty || snapshotStore.exists
    }

    /// 应用设置到目标设备。
    @discardableResult
    public func apply(_ settings: WindowsPointerSettings,
                      includeBuiltIn: Bool = false) -> [ServiceApplyResult]
    {
        guard !isApplying else { return lastResults }
        isApplying = true
        defer { isApplying = false }

        manager.refresh()
        let targets = manager.targetDevices(includeBuiltIn: includeBuiltIn)
        lastResults = targets.compactMap { apply(settings, to: $0) }
        if !lastResults.isEmpty {
            lastSettings = settings
        }
        return lastResults
    }

    /// 写回快照值。
    ///
    /// 原本不存在的属性写文档默认值而不是删除：`IOHIDServiceClientSetProperty`
    /// 传 NULL 不会通知 filter 插件（实测无 `Acceleration key:` 日志），
    /// filter 缓存会保留我们的值；写显式默认值才会触发它重新解析。
    public func restoreAll() {
        guard !isApplying else { return }
        isApplying = true
        defer { isApplying = false }

        manager.refresh()
        var snapshot = originals
        if snapshot.isEmpty {
            snapshot = snapshotStore.load().mapValues { properties in
                properties as [String: CFTypeRef]
            }
        }
        for (registryID, properties) in snapshot {
            guard let service = manager.service(for: registryID) else { continue }
            for key in PointerPropertyKey.managed {
                guard let value = properties[key] ?? defaultRestoreValue(for: key) else {
                    continue
                }
                setProperty(service, key, value: value)
            }
        }
        originals.removeAll()
        snapshotStore.clear()
        lastResults = []
        lastSettings = nil
    }

    /// 读取服务当前的全部受管属性，用于 `dump`。
    public func currentValues(for service: IOHIDServiceClient) -> [String: CFTypeRef?] {
        var values: [String: CFTypeRef?] = [:]
        for key in PointerPropertyKey.managed {
            values[key] = copyProperty(service, key)
        }
        values[PointerPropertyKey.reportRate] = copyProperty(service, PointerPropertyKey.reportRate)
        return values
    }

    // MARK: - Private

    private func apply(_ settings: WindowsPointerSettings,
                       to device: HIDPointerDevice) -> ServiceApplyResult? {
        guard let service = manager.service(for: device.registryID) else { return nil }

        var result = ServiceApplyResult(
            registryID: device.registryID, product: device.product,
            path: .unsupported, verified: false, lines: []
        )

        // 驱动自己发布的加速类型（内置触控板的 HIDTrackpadAcceleration）会在 filter
        // 清空属性缓存后重新生效，覆盖客户端的写入；这种服务改不动。
        // 判定在读枚举结果时即可完成，必须放在任何写入之前：触控板一个属性都不写。
        if let type = device.accelerationType,
           type != PointerPropertyKey.mouseAccelerationType
        {
            result.path = .unsupported
            result.lines.append("驱动已固定 HIDPointerAccelerationType=\(type)，"
                + "客户端写入会被驱动自己的值覆盖")
            result.lines.append("result: unsupported")
            return result
        }

        // 类型键是表/线性两条分支的开关，必须最先写。
        let typeAccepted = setProperty(service, PointerPropertyKey.accelerationType,
                    value: PointerPropertyKey.mouseAccelerationType as CFString)
        let resolutionAccepted = setProperty(
            service, PointerPropertyKey.resolution,
            value: PointerPropertyValue.fixed(WindowsPointerModel.pointerResolution))
        guard typeAccepted, resolutionAccepted else {
            result.lines.append("启动写入被拒绝（HIDPointerAccelerationType / HIDPointerResolution）")
            result.lines.append("result: unsupported")
            return result
        }

        // 只有确实会写入时才记录原值快照。
        captureOriginalIfNeeded(service, registryID: device.registryID)

        var order: [ServiceApplyResult.Path] = []
        if !settings.accelerationEnabled {
            order = [.linear]
        } else if device.hasParametricCurves {
            if let rate = device.reportRate, rate > 0 {
                order = [.parametric, .table]
            } else {
                order = [.table]
            }
        } else {
            order = [.table, .parametric]
        }

        for path in order {
            guard let plan = describe(path: path, settings: settings, device: device) else {
                result.lines.append("path=\(path.rawValue) 不适用（缺少报告率）")
                continue
            }
            // 属性写入落在 filter 插件的缓存里，服务本身不会发布回读值
            // （实测 macOS 27.2：IOHIDServiceClientCopyProperty 始终返回 nil）。
            // 因此以 `IOHIDServiceClientSetProperty` 的返回值为判据，
            // 驱动侧的确认见 ioHID 日志 `Acceleration key:... apply:yes`。
            result.path = path
            var accepted = true
            for write in plan where accepted {
                accepted = setProperty(service, write.key, value: write.value)
                if !accepted {
                    result.lines.append("path=\(path.rawValue) 写入被拒绝：\(write.key)")
                }
            }
            if !accepted {
                continue
            }
            result.verified = true
            result.lines.append("path=\(path.rawValue) written=true")
            for write in plan {
                result.lines.append("  \(write.key) = \(PointerPropertyValue.describe(write.value))")
            }
            break
        }

        if !result.verified {
            result.path = .unsupported
            result.lines.append("result: unsupported（两条路径都被驱动拒绝）")
        }
        return result
    }

    private struct Write {
        let key: String
        let value: CFTypeRef
    }

    /// 按路径生成完整写入列表。
    private func describe(path: ServiceApplyResult.Path,
                          settings: WindowsPointerSettings,
                          device: HIDPointerDevice) -> [Write]? {
        let multiplier = settings.multiplier
        switch path {
        case .linear:
            return [
                Write(key: PointerPropertyKey.useLinearScaling, value: PointerPropertyValue.fixed(1)),
                Write(key: PointerPropertyKey.mouseAcceleration,
                      value: PointerPropertyValue.fixed(multiplier)),
            ]
        case .table:
            return [
                Write(key: PointerPropertyKey.useLinearScaling, value: PointerPropertyValue.fixed(0)),
                Write(key: PointerPropertyKey.accelerationTable,
                      value: AccelerationTable.windowsTable(multiplier: multiplier) as CFData),
                Write(key: PointerPropertyKey.mouseAcceleration, value: PointerPropertyValue.fixed(1.5)),
            ]
        case .parametric:
            guard let rate = device.reportRate, rate > 0 else { return nil }
            let curves = AccelerationTable.parametricCurves(multiplier: multiplier, reportRate: rate)
            return [
                Write(key: PointerPropertyKey.useLinearScaling, value: PointerPropertyValue.fixed(0)),
                Write(key: PointerPropertyKey.accelCurves, value: curves as CFArray),
                Write(key: PointerPropertyKey.mouseAcceleration, value: PointerPropertyValue.fixed(123)),
            ]
        case .unsupported:
            return nil
        }
    }

    private func captureOriginalIfNeeded(_ service: IOHIDServiceClient, registryID: UInt64) {
        guard originals[registryID] == nil else { return }
        if let persisted = snapshotStore.load()[registryID] {
            // 其它进程（上一次运行）已经写过属性，沿用最早的快照，避免把已改写的值当成原值。
            originals[registryID] = persisted as [String: CFTypeRef]
            return
        }
        var snapshot: [String: CFTypeRef] = [:]
        for key in PointerPropertyKey.managed {
            if let value = copyProperty(service, key) {
                snapshot[key] = value
            }
        }
        originals[registryID] = snapshot
        snapshotStore.save(originals.mapValues { $0 as [String: Any] })
    }

    /// 属性原本不存在时的恢复值。
    private func defaultRestoreValue(for key: String) -> CFTypeRef? {
        switch key {
        case PointerPropertyKey.resolution:
            return PointerPropertyValue.fixed(WindowsPointerModel.pointerResolution)
        case PointerPropertyKey.useLinearScaling:
            return PointerPropertyValue.fixed(0)
        case PointerPropertyKey.accelerationTable:
            return AccelerationTable.defaultAccelTable as CFData
        case PointerPropertyKey.accelCurves:
            return SystemDefaults.accelCurves as CFArray?
        case PointerPropertyKey.mouseAcceleration:
            return PointerPropertyValue.fixed(SystemDefaults.mouseAcceleration)
        default:
            return nil
        }
    }

    private func copyProperty(_ service: IOHIDServiceClient,
                              _ key: String) -> CFTypeRef? {
        IOHIDServiceClientCopyProperty(service, key as CFString)
    }

    @discardableResult
    private func setProperty(_ service: IOHIDServiceClient,
                             _ key: String, value: CFTypeRef) -> Bool {
        IOHIDServiceClientSetProperty(service, key as CFString, value)
    }
}
