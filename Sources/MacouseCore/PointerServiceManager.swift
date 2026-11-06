import Foundation
import IOKit
import MacouseSPI

/// 枚举并持有 HID 指针服务。
///
/// 匹配集用 `IOHIDServiceClientConformsTo` 判定，而不是 `PrimaryUsagePage` /
/// `PrimaryUsage`：本机内置触控板的指针服务声明的是 `AppleMultitouchDevice`，
/// 用 matching 字典匹配 `{1,2}` / `{1,1}` 会得到 0 个服务（实测 macOS 27.2）。
/// 当没有任何服务声明鼠标 usage 时，退回「带 `HIDMouseAcceleration` 属性的服务」。
public final class PointerServiceManager {
    public private(set) var devices: [HIDPointerDevice] = []
    public private(set) var matchedServiceCount = 0

    /// 设备集合变化（插入/移除）后回调。
    public var onChange: (() -> Void)?

    private var client: IOHIDEventSystemClient?
    private var serviceArray: CFArray?
    private var queue: DispatchQueue?

    public init() {}

    deinit {
        stop()
    }

    /// 创建事件系统客户端、注册设备匹配回调并在 `queue` 上调度。
    public func start(queue: DispatchQueue = .main) {
        guard client == nil else { return }
        guard let newClient = IOHIDEventSystemClientCreate(kCFAllocatorDefault)?
            .takeRetainedValue()
        else {
            return
        }
        client = newClient
        self.queue = queue

        IOHIDEventSystemClientRegisterDeviceMatchingCallback(
            newClient,
            { context, _, _, _ in
                guard let context else { return }
                Unmanaged<PointerServiceManager>.fromOpaque(context)
                    .takeUnretainedValue()
                    .handleDevicesChanged()
            },
            Unmanaged.passUnretained(self).toOpaque()
        )
        IOHIDEventSystemClientScheduleWithDispatchQueue(newClient, queue)
        refresh()
    }

    public func stop() {
        guard let client else { return }
        IOHIDEventSystemClientUnregisterDeviceMatchingCallback(client)
        if let queue {
            IOHIDEventSystemClientUnscheduleFromDispatchQueue(client, queue)
        }
        self.client = nil
        self.queue = nil
        serviceArray = nil
        devices = []
        matchedServiceCount = 0
    }

    /// 重新枚举服务，并刷新 `devices`。
    @discardableResult
    public func refresh() -> [HIDPointerDevice] {
        guard let client else {
            devices = []
            matchedServiceCount = 0
            return devices
        }
        let services = IOHIDEventSystemClientCopyServices(client)
        serviceArray = services
        var pointerDevices: [HIDPointerDevice] = []
        var accelDevices: [HIDPointerDevice] = []
        if let services {
            let count = CFArrayGetCount(services)
            matchedServiceCount = count
            for index in 0..<count {
                let device = describe(service(at: index, in: services))
                if device.isPointerService {
                    pointerDevices.append(device)
                } else if device.hasMouseAccelerationProperty {
                    accelDevices.append(device)
                }
            }
        } else {
            matchedServiceCount = 0
        }
        devices = pointerDevices.isEmpty ? accelDevices : pointerDevices
        return devices
    }

    public func service(for registryID: UInt64) -> IOHIDServiceClient? {
        guard let services = serviceArray else { return nil }
        for index in 0..<CFArrayGetCount(services) {
            let service = service(at: index, in: services)
            if Self.registryID(of: service) == registryID {
                return service
            }
        }
        return nil
    }

    public static func registryID(of service: IOHIDServiceClient) -> UInt64 {
        (IOHIDServiceClientGetRegistryID(service) as? NSNumber)?.uint64Value ?? 0
    }

    private func service(at index: Int, in services: CFArray) -> IOHIDServiceClient {
        let raw = CFArrayGetValueAtIndex(services, index)!
        return Unmanaged<IOHIDServiceClient>.fromOpaque(raw).takeUnretainedValue()
    }

    /// 目标设备：默认只作用于外接（非内置）指针服务。
    ///
    /// 没有外接设备时返回空集合，绝不回退到内置触控板。
    /// `includeBuiltIn` 仅供 CLI 调试，App 不使用。
    public func targetDevices(includeBuiltIn: Bool) -> [HIDPointerDevice] {
        Self.targets(from: devices, includeBuiltIn: includeBuiltIn)
    }

    /// 纯选择逻辑，与 IOKit 解耦，便于单测。
    static func targets(from devices: [HIDPointerDevice],
                        includeBuiltIn: Bool) -> [HIDPointerDevice] {
        includeBuiltIn ? devices : devices.filter { !$0.isBuiltIn }
    }

    // MARK: - Private

    private func handleDevicesChanged() {
        refresh()
        onChange?()
    }

    private func describe(_ service: IOHIDServiceClient) -> HIDPointerDevice {
        let product = (copyProperty(service, "Product") as? String)
            ?? (copyProperty(service, "ProductString") as? String)
            ?? "unknown"
        let builtInFlag = (copyProperty(service, "Built-In") as? NSNumber)?.boolValue ?? false
        let looksBuiltIn = product.contains("Trackpad") || product.contains("Keyboard")
        let curves = copyProperty(service, PointerPropertyKey.accelCurves)
        let reportRate = (copyProperty(service, PointerPropertyKey.reportRate) as? NSNumber)
            .map { Int($0.int32Value) }
        let hasAccelProperty = copyProperty(service, PointerPropertyKey.mouseAcceleration) != nil
            || copyProperty(service, PointerPropertyKey.pointerAcceleration) != nil
        return HIDPointerDevice(
            registryID: Self.registryID(of: service),
            product: product,
            isBuiltIn: builtInFlag || looksBuiltIn,
            hasParametricCurves: (curves as? [Any])?.isEmpty == false,
            reportRate: reportRate,
            conformsToMouse: IOHIDServiceClientConformsTo(service, 1, 2) != 0,
            conformsToPointer: IOHIDServiceClientConformsTo(service, 1, 1) != 0,
            hasMouseAccelerationProperty: hasAccelProperty,
            accelerationType: copyProperty(service, PointerPropertyKey.accelerationType) as? String
        )
    }

    private func copyProperty(_ service: IOHIDServiceClient,
                              _ key: String) -> CFTypeRef? {
        IOHIDServiceClientCopyProperty(service, key as CFString)
    }
}
