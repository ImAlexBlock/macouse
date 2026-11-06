import XCTest
@testable import MacouseCore

final class WindowsPointerModelTests: XCTestCase {
    func testSpeedMultipliersMatchWindowsNotches() {
        XCTAssertEqual(WindowsPointerModel.speedMultipliers.count, 11)
        XCTAssertEqual(WindowsPointerModel.multiplier(forPosition: 1), 0.1, accuracy: 1e-12)
        XCTAssertEqual(WindowsPointerModel.multiplier(forPosition: 6), 1.0, accuracy: 1e-12)
        XCTAssertEqual(WindowsPointerModel.multiplier(forPosition: 11), 2.0, accuracy: 1e-12)
        XCTAssertEqual(WindowsPointerSettings(speedPosition: 6).multiplier, 1.0)
    }

    func testSpeedPositionClamping() {
        XCTAssertEqual(WindowsPointerModel.clampPosition(0), 1)
        XCTAssertEqual(WindowsPointerModel.clampPosition(12), 11)
        XCTAssertEqual(WindowsPointerModel.clampPosition(6), 6)
        XCTAssertEqual(WindowsPointerSettings(speedPosition: 99).speedPosition, 11)
    }

    func testWindowsCurveAnchors() {
        let points = WindowsPointerModel.windowsCurvePoints
        XCTAssertEqual(points.count, 5)
        XCTAssertEqual(points[0].x, 0)
        XCTAssertEqual(points[0].y, 0)
        XCTAssertEqual(points[1].x, 0.4300079345703125)
        XCTAssertEqual(points[1].y, 1.0702667236328125)
        XCTAssertEqual(points[2].x, 1.25)
        XCTAssertEqual(points[2].y, 4.140625)
        XCTAssertEqual(points[3].x, 3.8600006103515625)
        XCTAssertEqual(points[3].y, 18.984375)
        XCTAssertEqual(points[4].x, 40.0)
        XCTAssertEqual(points[4].y, 443.75)
    }

    func testDriverScalesMatchAppleConstants() {
        XCTAssertEqual(WindowsPointerModel.frameRate, 67.0)
        XCTAssertEqual(WindowsPointerModel.cursorScale, 96.0 / 67.0, accuracy: 1e-15)
        XCTAssertEqual(WindowsPointerModel.pointerResolution, 400.0)
        // x 轴换算让驱动速度轴等于 Windows 的 125 Hz 速度轴。
        XCTAssertEqual(WindowsPointerModel.tableXScale, 67.0 / 400.0, accuracy: 1e-15)
        // 原点斜率：Windows 曲线把它归一成慢速 1:1。
        XCTAssertEqual(WindowsPointerModel.originSlope, 2.4889464532841274, accuracy: 1e-12)
        XCTAssertEqual(WindowsPointerModel.tableYScale, 1.0 / (2.4889464532841274 * 96.0 / 67.0),
                       accuracy: 1e-15)
        XCTAssertEqual(WindowsPointerModel.tableYScale, 0.2804064610332521, accuracy: 1e-12)
    }

    func testSettingsRoundTripThroughDefaults() {
        let suite = UserDefaults(suiteName: "dev.alexblock.macouse.tests")!
        suite.removePersistentDomain(forName: "dev.alexblock.macouse.tests")
        let store = SettingsStore(defaults: suite)
        XCTAssertTrue(store.settings.accelerationEnabled)
        XCTAssertEqual(store.settings.speedPosition, 6)

        store.settings = WindowsPointerSettings(accelerationEnabled: false, speedPosition: 9)
        XCTAssertFalse(store.settings.accelerationEnabled)
        XCTAssertEqual(store.settings.speedPosition, 9)
        XCTAssertEqual(store.settings.multiplier, 1.6, accuracy: 1e-12)
        suite.removePersistentDomain(forName: "dev.alexblock.macouse.tests")
    }
}
