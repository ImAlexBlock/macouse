# Repository Guidelines

## Project Overview

Macouse is a macOS menu-bar app plus CLI that remaps the **Windows pointer model** (acceleration toggle + 1…11 speed notches) onto the pointer-acceleration properties that Apple's HID stack reads (`AppleUserHIDEventDriver`, `IOHIDPointerScrollFilter`).

- No driver install, no event injection, no event taps. It writes service properties via `IOHIDServiceClientSetProperty`.
- One windowless `LSUIElement` app (`dev.alexblock.macouse`) and one diagnostic CLI.
- Minimum macOS 14; the numeric model mirrors `IOHIDPointerScrollFilter.cpp` / `IOHIDAccelerationTable.hpp`.

## Architecture & Data Flow

Layering (`Package.swift`):

```
MacouseSPI (C shim, links IOKit)
   └── MacouseCore (all logic)
          ├── MacouseApp   (menu bar executable)
          └── macouse-cli  (executable)
MacouseCoreTests ──> MacouseCore
```

Apply chain:

1. `PopoverView` binding changes → `AppModel.update()` (`Sources/MacouseApp/AppModel.swift`).
2. `SettingsStore.settings` writes `UserDefaults` keys `accelerationEnabled` / `speedPosition`.
3. `AppModel.apply()` → `PointerSettingsApplier.apply(_:includeBuiltIn:)`.
4. `PointerServiceManager.refresh()` → `targetDevices(includeBuiltIn:)` → `service(for:)`.
5. Per device, `describe(path:…)` builds `[Write]`, written with `IOHIDServiceClientSetProperty`.

Path selection inside `PointerSettingsApplier` — three mutually exclusive branches:

| Condition | Path | Key writes |
| --- | --- | --- |
| acceleration off | linear | `HIDUseLinearScalingMouseAcceleration = 1`, `HIDMouseAcceleration = multiplier` |
| service has no `HIDAccelCurves` | table | `HIDPointerAccelerationTable`, `HIDMouseAcceleration = 1.5` |
| service has `HIDAccelCurves` | parametric | `HIDAccelCurves`, `HIDMouseAcceleration = 123` |

`HIDPointerAccelerationType` is the branch switch and MUST be written first (`PointerSettingsApplier.swift`).

Snapshot / rollback:

- `SnapshotStore` persists originals to `~/Library/Application Support/Macouse/originals.plist` (binary plist, atomic write, keyed by decimal `registryID`).
- Originals are captured only after the type/resolution prewrite succeeds; the persisted snapshot wins over a live read.
- `restoreAll()` writes **explicit default values, never NULL** — passing NULL does not notify the filter plugin, whose cache would keep the injected value.
- App restores a stale snapshot at launch and always restores on `applicationWillTerminate`.

Concurrency model: single `DispatchQueue.main` passed to `IOHIDEventSystemClientScheduleWithDispatchQueue`. No `async`/`await`, actors, or `@MainActor` anywhere; the C callback trampolines via `Unmanaged.passUnretained(self)`. `PointerSettingsApplier` uses an `isApplying` bool reentrancy guard, not locks.

## Key Directories

| Path | Contents |
| --- | --- |
| `Sources/MacouseCore/` | Windows model, acceleration table encoding, HID device/service access, snapshot + settings stores |
| `Sources/MacouseApp/` | AppKit lifecycle (`@main`-less `main.swift`, `AppDelegate`), status item, `AppModel`, SwiftUI popover |
| `Sources/macouse-cli/` | `list`, `dump`, `apply`, `restore`, `debug` subcommands |
| `Sources/MacouseSPI/` | `MacouseSPI.h` private IOKit declarations + link-anchor `.c` |
| `Tests/MacouseCoreTests/` | XCTest suites for table/model math and target selection |
| `Resources/Info.plist` | Bundle manifest copied verbatim into the `.app` |
| `build/Macouse.app` | Build output from `./build.sh` |

## Development Commands

```bash
swift test                                   # unit tests (XCTest)
swift build -c release --product Macouse      # app binary
./build.sh                                   # release build → build/Macouse.app → ad-hoc sign
open build/Macouse.app                       # run (menu bar icon, no Dock icon)

swift run macouse-cli list    [--include-built-in]
swift run macouse-cli dump    [--include-built-in]
swift run macouse-cli apply   --accel on|off --speed 1..11 [--include-built-in]
swift run macouse-cli restore
swift run macouse-cli debug   [--include-built-in]
```

No lint, format, or CI configuration exists in this repository. Do not introduce a "lint" command.

## Code Conventions & Common Patterns

- **One type per file, filename == type name.** A new type gets a new file.
- **Access control marks the module boundary:** `public` in `MacouseCore`; `internal final class` for App types.
- **Chinese** doc comments and all user-facing strings. "Why" comments cite the Apple driver source or an observed `log show` line.
- **Constructor injection with default arguments** (`SettingsStore(defaults: .standard)`, `PointerSettingsApplier(manager:snapshotStore:)`), concrete classes, no protocols, no singletons.
- **No throwing APIs in Core.** Failures surface as `Bool` returns, `CFTypeRef?`, `try?`, or collected `ServiceApplyResult` lines. Only the CLI exits (`fail()` → stderr + `exit(2)`).
- **Value types are `Sendable`;** CF service refs are passed directly, never stored across threads.
- **Keep driver constants centralized:** multipliers, curve anchors, `FRAME_RATE`, `kCursorScale`, `tableXScale`, `tableYScale` live in `WindowsPointerModel` / `AccelerationTable`. Never inline a second copy.
- **Endianness is a correctness invariant, not a bug:** table `scale`/`count`/`accel`/points are big-endian (`OSReadBigInt32`), the signature is native-ordered. Do not "normalize" it.
- **16.16 fixed point** goes through `AccelerationTable.fixed(_:)`; `HIDPointerResolution` for 400 is `26214400`.
- **SPI scope:** `MacouseSPI.h` declares only the five event-system-client symbols that are absent from the public SDK. Do not redeclare public IOKit symbols; the `.c` file is a link anchor only.
- **Targeting is mouse-only by default:** `targetDevices(includeBuiltIn:)` filters out services flagged built-in, with no fallback to the trackpad when no mouse exists. A service whose published `HIDPointerAccelerationType` is not `HIDMouseAcceleration` is rejected as `unsupported` **before any write**. `includeBuiltIn` is CLI-debug only.
- **C callback parameters Swift does not read must be `void *`.** Typing an unused parameter as a CF/ObjC type makes the Swift trampoline `objc_retain` it. IOKit passes an invalid pointer on device-matching refreshes (`0x103`), so the process dies with `EXC_BAD_ACCESS` on mouse plug/unplug. See `MacouseSPI.h`.
- **UI is AppKit-hosted SwiftUI:** `NSStatusItem` + `NSPopover` + `NSHostingController`, `ObservableObject`/`@Published` only. No Combine pipelines, no SwiftUI `App` lifecycle.
- **CLI parses `argv` manually;** no ArgumentParser dependency.

## Important Files

| File | Role |
| --- | --- |
| `Package.swift` | Tools 6.0, `.macOS(.v14)`, `swiftLanguageModes: [.v5]`, IOKit linkage |
| `build.sh` | Release build → bundle assembly → `codesign --sign -` → verify |
| `Sources/MacouseCore/WindowsPointerModel.swift` | Settings value types, speed notches, Windows curve anchors, scale constants |
| `Sources/MacouseCore/AccelerationTable.swift` | Binary `ACCEL_TABLE` encoder, parametric curve builder, fixed-point helpers |
| `Sources/MacouseCore/PointerSettingsApplier.swift` | Path selection, property writes, snapshot/restore |
| `Sources/MacouseCore/PointerServiceManager.swift` | Event-system client lifecycle, service enumeration, target filtering |
| `Sources/MacouseCore/SnapshotStore.swift` | Original-property plist persistence |
| `Sources/MacouseCore/SettingsStore.swift` | `UserDefaults` persistence (`accelerationEnabled`, `speedPosition`, defaults `true`/`6`) |
| `Sources/MacouseApp/AppModel.swift` | Single UI state object bridging store ↔ applier |
| `Sources/macouse-cli/main.swift` | Subcommand dispatch, exit codes `0`/`1`/`2` |
| `Sources/MacouseSPI/include/MacouseSPI.h` | Private IOKit SPI declarations (adapted from LinearMouse, MIT) |

## Runtime/Tooling Preferences

- Swift 6.0 toolchain required by the manifest, **Swift 5 language mode**; no package dependencies.
- macOS 14+ deployment; verified on macOS 27.2.
- Packaging is ad-hoc signing with no entitlements, no hardened runtime, and no notarization. Transferred `.app` copies hit Gatekeeper quarantine; only local builds run cleanly.
- No TCC/Accessibility APIs are used; do not add usage descriptions or entitlements without a functional need.
- This checkout has no `.git` metadata and no workflow files. Do not assume VCS or CI operations are available.

## Testing & QA

- Framework: **XCTest** with `@testable import MacouseCore`; files under `Tests/MacouseCoreTests/`, 18 test methods total.
- Run: `swift test`; target-scope with `swift test --filter AccelerationTableTests`. XCTest modules come only from Xcode, so when `xcode-select` points at CommandLineTools run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`.
- Suites:
  - `AccelerationTableTests` — byte layout, big-endian vs native signature, driver-decoded gains/breakpoints, parametric linearity, report-rate independence, fixed-point rounding/clamping.
  - `WindowsPointerModelTests` — speed notch multipliers, clamping, Apple/Windows constants, `UserDefaults` round-trip.
  - `PointerTargetingTests` — default selection excludes built-in services, no fallback when only a trackpad exists.
- Isolation rules: float assertions use `XCTAssertEqual(_:_:accuracy:)`; stateful tests use `UserDefaults(suiteName: "dev.alexblock.macouse.tests")` with `removePersistentDomain`. No IOKit access, mocks, sleeps, or ordering dependencies.
- Untested by design (IOKit/system-bound): `PointerServiceManager`, `PointerSettingsApplier` writes, `SystemDefaults`, `SnapshotStore` I/O. Add a seam via injected URL/`UserDefaults` rather than touching live services in tests.
- Hardware behavior cannot be verified in tests. Confirm writes with `log show --predicate 'eventMessage CONTAINS "Acceleration key"'`; keep README's 已验证/未验证 separation when stating results.
