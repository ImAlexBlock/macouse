import AppKit
import Combine
import Foundation
import MacouseCore

/// 菜单栏界面的状态：设置本身 + 应用结果。
final class AppModel: ObservableObject {
    @Published var accelerationEnabled: Bool
    @Published var speedPosition: Int
    @Published private(set) var statusText = ""
    @Published private(set) var detailText = ""
    @Published private(set) var needsInputMonitoringPermission = false

    private let store: SettingsStore
    private let applier: PointerSettingsApplier
    private let manager: PointerServiceManager

    init(store: SettingsStore, applier: PointerSettingsApplier, manager: PointerServiceManager) {
        self.store = store
        self.applier = applier
        self.manager = manager
        let settings = store.settings
        accelerationEnabled = settings.accelerationEnabled
        speedPosition = settings.speedPosition
    }

    var multiplier: Double {
        WindowsPointerModel.multiplier(forPosition: speedPosition)
    }

    /// 用户改动后写盘并应用。
    func update() {
        store.settings = WindowsPointerSettings(accelerationEnabled: accelerationEnabled,
                                                speedPosition: speedPosition)
        apply()
    }

    func apply() {
        let settings = WindowsPointerSettings(accelerationEnabled: accelerationEnabled,
                                              speedPosition: speedPosition)
        let results = applier.apply(settings)
        updateStatus(results: results)
    }

    /// 恢复系统默认并同步界面。
    func restoreSystemDefault() {
        applier.restoreAll()
        accelerationEnabled = true
        speedPosition = 6
        store.settings = WindowsPointerSettings()
        updateStatus(results: [])
    }

    func openInputMonitoringSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
        else { return }
        NSWorkspace.shared.open(url)
    }

    private func updateStatus(results: [ServiceApplyResult]) {
        if manager.matchedServiceCount == 0 {
            statusText = "未检测到 HID 指针服务"
            detailText = ""
            needsInputMonitoringPermission = true
            return
        }
        needsInputMonitoringPermission = false
        let targets = manager.targetDevices(includeBuiltIn: false)
        let verified = results.filter(\.verified).count
        if targets.isEmpty {
            statusText = "未检测到外接鼠标"
            detailText = "只作用于鼠标，不改写内置触控板"
            return
        }
        statusText = "\(verified) 个鼠标设备"
        if results.contains(where: { !$0.verified }) {
            detailText = "该设备不支持改写指针参数（驱动固定了加速类型）"
        } else if let path = results.first?.path {
            detailText = path == .linear
                ? "线性（无加速）"
                : "Windows 曲线（\(path == .table ? "表式" : "参数化")）"
        } else {
            detailText = ""
        }
    }
}
