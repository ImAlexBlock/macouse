import XCTest
@testable import MacouseCore

final class PointerTargetingTests: XCTestCase {
    private func device(_ registryID: UInt64, builtIn: Bool) -> HIDPointerDevice {
        HIDPointerDevice(
            registryID: registryID,
            product: builtIn ? "Apple Internal Keyboard / Trackpad" : "USB Optical Mouse",
            isBuiltIn: builtIn,
            hasParametricCurves: false,
            reportRate: 125,
            conformsToMouse: true,
            conformsToPointer: false,
            hasMouseAccelerationProperty: true,
            accelerationType: builtIn ? "HIDTrackpadAcceleration" : nil
        )
    }

    func testDefaultTargetsExcludeBuiltIn() {
        let devices = [device(1, builtIn: false), device(2, builtIn: true)]
        let targets = PointerServiceManager.targets(from: devices, includeBuiltIn: false)
        XCTAssertEqual(targets.map(\.registryID), [1])
    }

    func testNoFallbackToBuiltInWithoutExternalDevice() {
        let devices = [device(2, builtIn: true)]
        XCTAssertTrue(PointerServiceManager.targets(from: devices, includeBuiltIn: false).isEmpty)
    }

    func testIncludeBuiltInReturnsEveryDevice() {
        let devices = [device(1, builtIn: false), device(2, builtIn: true)]
        let targets = PointerServiceManager.targets(from: devices, includeBuiltIn: true)
        XCTAssertEqual(targets.map(\.registryID), [1, 2])
    }
}
