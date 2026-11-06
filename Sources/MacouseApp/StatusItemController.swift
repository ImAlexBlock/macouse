import AppKit
import SwiftUI

/// 菜单栏图标 + popover。
final class StatusItemController {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()

    init(model: AppModel) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "computermouse",
                                          accessibilityDescription: "Macouse")
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.target = self

        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: PopoverView(model: model))
        popover.contentSize = NSSize(width: 300, height: 200)
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
