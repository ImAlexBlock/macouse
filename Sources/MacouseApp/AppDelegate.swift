import AppKit
import MacouseCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let manager = PointerServiceManager()
    private let store = SettingsStore()
    private lazy var applier = PointerSettingsApplier(manager: manager)
    private var model: AppModel?
    private var statusController: StatusItemController?
    private var wakeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        manager.start(queue: .main)
        manager.onChange = { [weak self] in
            self?.reapply()
        }

        let model = AppModel(store: store, applier: applier, manager: manager)
        self.model = model
        statusController = StatusItemController(model: model)

        // 上一次运行可能崩溃在已写入状态；先恢复，再按已保存设置写入。
        if applier.hasSnapshot {
            applier.restoreAll()
        }
        model.apply()

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.reapply()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        applier.restoreAll()
    }

    private func reapply() {
        model?.apply()
    }
}
