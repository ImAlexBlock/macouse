# Macouse

macOS 菜单栏 App：把 Windows 的鼠标指针逻辑（鼠标加速度开关 + 1…11 档速度）映射到 Apple HID 驱动的指针加速属性上。

不装驱动，不做事件注入。写入的是 `AppleUserHIDEventDriver` / `IOHIDPointerScrollFilter` 读取的指针加速属性，因此没有额外延迟，也保留亚像素。

## 用法

```bash
swift test                      # 单元测试
./build.sh                      # 打包 build/Macouse.app（ad-hoc 签名）
open build/Macouse.app          # 菜单栏出现鼠标图标，无 Dock 图标
```

CLI 用于检查和写入：

```bash
swift run macouse-cli list    [--include-built-in]
swift run macouse-cli dump    [--include-built-in]
swift run macouse-cli apply   --accel on|off --speed 1..11 [--include-built-in]
swift run macouse-cli restore
swift run macouse-cli debug   [--include-built-in]   # filter 插件调试字典
```

App 关闭时会写回原值。原值快照保存在 `~/Library/Application Support/Macouse/originals.plist`，
所以崩溃后重启 App 也能恢复。

默认只作用于外接鼠标：目标选择跳过 `Built-In` 为真、或产品名含 `Trackpad` / `Keyboard` 的服务。
没有外接设备时不做任何写入，App 状态显示「未检测到外接鼠标」。`--include-built-in` 仅供调试，
触控板仍会被驱动固定的加速类型挡在写入之前。

## 实现要点（源码级事实）

模型来自 Apple `IOHIDFamily` 的 `IOHIDPointerScrollFilter.cpp`、`IOHIDAccelerationAlgorithm.cpp`、
`IOHIDAccelerationTable.hpp/.cpp`：

| 事实 | 值 |
| --- | --- |
| 驱动常量 `FRAME_RATE` | 67 |
| 驱动常量 `kCursorScale` | 96/67 |
| `HIDPointerResolution` 编码 | 16.16 定点（`fixed(400) = 26214400`） |
| 表式速度轴 | `table.x · resolution / FRAME_RATE` |
| 表式输出 | `table.y · kCursorScale`，线段斜率即 px/count |
| 参数化速度轴 | `velocity · HIDPointerReportRate / resolution` |
| 参数化输出 | `f(x) · kCursorScale / velocity` |
| 线性分支条件 | `HIDPointerAccelerationType == "HIDMouseAcceleration"` 且 `HIDUseLinearScalingMouseAcceleration != 0` |

两条路径（依据 `createPointerAlgorithm`）：

- 服务没有 `HIDAccelCurves` → 表路径：`HIDPointerAccelerationTable`、`HIDMouseAcceleration = 1.5`。
- 服务已有 `HIDAccelCurves` → 参数化路径：`HIDAccelCurves`、`HIDMouseAcceleration = 123`。
- 加速关闭 → 线性路径：`HIDUseLinearScalingMouseAcceleration = 1`、`HIDMouseAcceleration = 倍率`。

### 加速表的字节序陷阱

`ACCEL_TABLE` 的字段解析方式不一致，写错一处整张表会被驱动静默丢弃：

- `scale`、`count`、`accel`、每个点的 `x`/`y`：大端（`OSReadBigInt32` / `OSReadBigInt16`）。
- `signature`：原生读取（`ACCEL_TABLE::signature()` 直接返回字段）。因此在 arm64 上
  存 `0x30303240` 必须写成小端字节 `40 32 30 30`。

### Windows 曲线怎么落到驱动上

Windows 曲线按 125 Hz 报告率定义速度轴，归一化增益用原点斜率 `2.4889464532841274`：

- 表路径：存 `x · 67/400`、`y · m / (原点斜率 · 96/67)`。驱动物理出的线段增益正好是
  `Windows 归一化增益 × m`，断点落在 Windows 的速度坐标上（单测按驱动算法解码验证）。
- 参数化路径：`cᵢ = aᵢ · (400/125) · λ^(1/(i+1))`，其中
  `λ = m · 125 / (原点斜率 · 96/67 · 报告率)`。
- 线性路径（加速关闭）：`px/count = m`，与 Windows 6/11 加速关闭的 1:1 一致。

### 设备变更回调的声明陷阱

`IOHIDEventSystemClientRegisterDeviceMatchingCallback` 的第 4 个参数在头文件里声明为 `void *`。
若声明成 `IOHIDServiceClientRef`，Swift 生成的 trampoline 会在回调入口对该参数执行
`objc_retain`。刷新通知传入的值不是可 retain 的对象（实测为 `0x103`），进程随即
`EXC_BAD_ACCESS`。表现就是插拔鼠标时 App 直接消失。回调本身不使用该参数。

## 已验证 / 未验证

在本机（macOS 27.2，无外接鼠标，内置触控板）：

- `swift test`：18 个测试通过（曲线锚点、编码字节、按驱动算法解码出的增益与断点、倍率线性、报告率无关性、目标选择）。
- CLI 与 App 都能枚举到触控板的指针服务（registryID `0x100000cbc`，`HIDPointerReportRate = 120`，
  `HIDAccelCurves` 10 条，`HIDPointerAccelerationTable` 771 字节）。
- 默认路径不写触控板：`apply --include-built-in` 返回 `unsupported`，`dump` 前后一致。
- 早期版本在内置触控板上做的预写曾被驱动消费（`log show --predicate 'eventMessage CONTAINS "Acceleration key"'`
  显示 `Acceleration key:HIDPointerAccelerationType value:HIDMouseAcceleration apply:yes`）。该预写已移除，
  这条日志不能作为当前版本的证据。
- **未验证**：外接鼠标上的实际写入与物理手感（本机无外接鼠标）。

## 已知限制

1. `IOHIDServiceClientSetProperty` 写入只落在 filter 插件的缓存里，服务本身不保存也无法回读
   （跨进程读取仍是旧值）。filter 每次 `setupAcceleration()` 之后清空缓存并重新读服务属性，
   因此服务自己发布的键会覆盖写入。
2. 内置触控板的 `HIDPointerAccelerationType` 由驱动固定为 `HIDTrackpadAcceleration`，
   于是 `isMouseAcceleration == false`，线性分支与自定义曲线都不会被采用。
   判定在枚举结果上完成，早于任何 `IOHIDServiceClientSetProperty` 调用，所以触控板一个属性都不会写；
   报告结果是 `unsupported`。默认目标选择也不再包含内置设备，没有外接鼠标时不回退。
3. 表路径与参数化曲线所用的 `HIDPointerAccelerationTable` / `HIDAccelCurves` 只能通过服务属性
   提供，客户端写不进去；`HIDUserPointerAccelCurves` 这类用户覆盖键在本机 SDK 中找不到可用的键名
   （十种候选全部被忽略）。
4. 因此在本机无法改变指针行为；对外接鼠标（服务通常没有 `HIDPointerAccelerationType`）应当可用，
   但本机无外接鼠标，这一点未验证。
5. 游戏若用 Raw Input / 独占模式直接读鼠标，不经过该管线，任何实现都无法影响。
