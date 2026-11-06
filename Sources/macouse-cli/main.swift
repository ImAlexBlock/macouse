import Foundation
import MacouseCore
import MacouseSPI

// macouse-cli：命令行检查与写入 HID 指针加速属性。
//
//   macouse-cli list    [--include-built-in]
//   macouse-cli dump    [--include-built-in]
//   macouse-cli apply   --accel on|off --speed N [--include-built-in]
//   macouse-cli restore
//   macouse-cli debug   [--include-built-in]

private let usage = """
usage:
  macouse-cli list    [--include-built-in]
  macouse-cli dump    [--include-built-in]
  macouse-cli apply   --accel on|off --speed 1...11 [--include-built-in]
  macouse-cli restore
  macouse-cli debug   [--include-built-in]

--include-built-in  把内置触控板也作为目标（仅调试；默认只作用于外接鼠标）
"""

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

private func describe(_ value: CFTypeRef?) -> String {
    PointerPropertyValue.describe(value)
}

private func printDevices(_ manager: PointerServiceManager, includeBuiltIn: Bool) {
    let targets = Set(manager.targetDevices(includeBuiltIn: includeBuiltIn).map(\.registryID))
    for device in manager.devices {
        let target = targets.contains(device.registryID) ? "target" : "-"
        let rate = device.reportRate.map(String.init) ?? "nil"
        print("\(device.registryID) \(device.product) builtIn=\(device.isBuiltIn) "
            + "curves=\(device.hasParametricCurves) reportRate=\(rate) \(target)")
    }
}

private func dump(_ manager: PointerServiceManager, applier: PointerSettingsApplier,
                  includeBuiltIn: Bool)
{
    printDevices(manager, includeBuiltIn: includeBuiltIn)
    for device in manager.targetDevices(includeBuiltIn: includeBuiltIn) {
        guard let service = manager.service(for: device.registryID) else { continue }
        print("# \(device.product) registryID=\(device.registryID)")
        let values = applier.currentValues(for: service)
        for key in PointerPropertyKey.managed + [PointerPropertyKey.reportRate] {
            let value = values[key] ?? nil
            if key == PointerPropertyKey.reportRate,
               let number = value as? NSNumber
            {
                // 报告率是整数属性，不做 16.16 解释。
                print("  \(key) = \(number.intValue)")
                continue
            }
            print("  \(key) = \(describe(value))")
        }
    }
}

private func debugDump(_ manager: PointerServiceManager, applier: PointerSettingsApplier,
                       includeBuiltIn: Bool)
{
    for device in manager.targetDevices(includeBuiltIn: includeBuiltIn) {
        guard let service = manager.service(for: device.registryID) else { continue }
        print("# \(device.product) registryID=\(device.registryID)")
        let value = IOHIDServiceClientCopyProperty(service, "ServiceFilterDebug" as CFString)
        if let value {
            print(String(describing: value))
        } else {
            print("<absent>")
        }
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first ?? ""
if command.isEmpty || ["-h", "--help", "help"].contains(command) {
    print(usage)
    exit(command.isEmpty ? 2 : 0)
}

var includeBuiltIn = false
var acceleration: Bool?
var speed = 6
var index = 1
while index < arguments.count {
    switch arguments[index] {
    case "--include-built-in":
        includeBuiltIn = true
        index += 1
    case "--accel":
        guard index + 1 < arguments.count else { fail("--accel 需要 on|off") }
        switch arguments[index + 1] {
        case "on": acceleration = true
        case "off": acceleration = false
        default: fail("--accel 只接受 on|off")
        }
        index += 2
    case "--speed":
        guard index + 1 < arguments.count, let value = Int(arguments[index + 1]) else {
            fail("--speed 需要 1...11 的整数")
        }
        guard WindowsPointerModel.positions.contains(value) else {
            fail("--speed 取值 1...11")
        }
        speed = value
        index += 2
    default:
        fail("未知参数 \(arguments[index])")
    }
}

let manager = PointerServiceManager()
manager.start(queue: .main)
let applier = PointerSettingsApplier(manager: manager)

switch command {
case "list":
    printDevices(manager, includeBuiltIn: includeBuiltIn)
    let external = manager.devices.filter { !$0.isBuiltIn }.count
    print("# \(external) 个外接指针设备，\(manager.devices.count) 个匹配服务")
    exit(0)

case "dump":
    dump(manager, applier: applier, includeBuiltIn: includeBuiltIn)
    exit(0)

case "debug":
    debugDump(manager, applier: applier, includeBuiltIn: includeBuiltIn)
    exit(0)

case "apply":
    guard let acceleration else { fail("apply 需要 --accel on|off") }
    let settings = WindowsPointerSettings(accelerationEnabled: acceleration,
                                         speedPosition: speed)
    let results = applier.apply(settings, includeBuiltIn: includeBuiltIn)
    guard !results.isEmpty else {
        print("没有外接鼠标（默认不改写内置触控板；调试可用 --include-built-in）")
        exit(1)
    }
    print("settings: accel=\(settings.accelerationEnabled) position=\(settings.speedPosition)/11 "
        + "multiplier=\(settings.multiplier)×")
    var failures = 0
    for result in results {
        print("# \(result.product) registryID=\(result.registryID)")
        for line in result.lines { print("  \(line)") }
        if !result.verified { failures += 1 }
    }
    if failures > 0 {
        print("\(failures)/\(results.count) 个服务失败")
        exit(1)
    }
    exit(0)

case "restore":
    guard applier.hasSnapshot else {
        print("没有待恢复的快照（本机未写入过属性）")
        exit(1)
    }
    applier.restoreAll()
    dump(manager, applier: applier, includeBuiltIn: true)
    exit(0)

default:
    fail("未知子命令 \(command)\n\n\(usage)")
}

