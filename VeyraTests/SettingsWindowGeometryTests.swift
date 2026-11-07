import XCTest
import Foundation

final class SettingsWindowGeometryTests: XCTestCase {
    private let desktop = CGRect(x: 0, y: 40, width: 1440, height: 860)

    func testUsesLargestIntersectionIncludingNegativeScreenOrigins() {
        let screens = [desktop, CGRect(x: -1200, y: 0, width: 1200, height: 800)]
        XCTAssertEqual(SettingsWindowGeometry.screenIndex(
            for: CGRect(x: -600, y: 100, width: 800, height: 600), visibleFrames: screens,
            mouseLocation: CGPoint(x: 100, y: 100), mainIndex: 0), 1)
    }

    func testDisconnectedScreenFallsBackToMouseThenMain() {
        let screens = [desktop, CGRect(x: -1200, y: 0, width: 1200, height: 800)]
        let saved = CGRect(x: 5000, y: 100, width: 700, height: 600)
        XCTAssertEqual(SettingsWindowGeometry.screenIndex(for: saved, visibleFrames: screens,
            mouseLocation: CGPoint(x: -500, y: 100), mainIndex: 0), 1)
        XCTAssertEqual(SettingsWindowGeometry.screenIndex(for: saved, visibleFrames: screens,
            mouseLocation: CGPoint(x: 5000, y: 5000), mainIndex: 0), 0)
        XCTAssertNil(SettingsWindowGeometry.screenIndex(for: saved, visibleFrames: [], mouseLocation: .zero, mainIndex: nil))
    }

    func testOrdinaryWindowKeepsSizeAndPosition() {
        let original = CGRect(x: 130, y: 120, width: 680, height: 522)
        let value = SettingsWindowGeometry.placement(for: original, visibleFrame: desktop, chromeHeight: 22)
        XCTAssertEqual(value.frame, original)
        XCTAssertEqual(value.minimumContentSize, CGSize(width: 570, height: 440))
    }

    func testPointerOverSecondaryMenuBarStillChoosesThatDisplay() {
        let visible = [desktop, CGRect(x: -1200, y: 0, width: 1200, height: 770)]
        let full = [CGRect(x: 0, y: 0, width: 1440, height: 900), CGRect(x: -1200, y: 0, width: 1200, height: 800)]
        XCTAssertEqual(SettingsWindowGeometry.screenIndex(for: .zero, visibleFrames: visible, screenFrames: full,
            mouseLocation: CGPoint(x: -600, y: 790), mainIndex: 0), 1)
    }

    func testSmallScreenClampsFullFrameIncludingTitleBar() {
        let screen = CGRect(x: 100, y: 60, width: 800, height: 600)
        let value = SettingsWindowGeometry.placement(for: CGRect(x: -200, y: -100, width: 1000, height: 900),
            visibleFrame: screen, chromeHeight: 28)
        XCTAssertEqual(value.frame, screen)
        XCTAssertEqual(value.minimumContentSize, CGSize(width: 570, height: 440))
    }

    func testVerySmallScreenTemporarilyLowersContentMinimum() {
        let screen = CGRect(x: -500, y: 20, width: 400, height: 340)
        let value = SettingsWindowGeometry.placement(for: desktop, visibleFrame: screen, chromeHeight: 28)
        XCTAssertEqual(value.frame, screen)
        XCTAssertEqual(value.minimumContentSize, CGSize(width: 400, height: 312))
        let larger = SettingsWindowGeometry.placement(for: value.frame, visibleFrame: desktop, chromeHeight: 28)
        XCTAssertEqual(larger.minimumContentSize, CGSize(width: 570, height: 440))
        XCTAssertEqual(larger.frame.size, CGSize(width: 570, height: 468))
    }

    func testMovedWindowOnlyCorrectsOffscreenPortion() {
        let value = SettingsWindowGeometry.placement(for: CGRect(x: 1200, y: 800, width: 600, height: 600),
            visibleFrame: desktop, chromeHeight: 22)
        XCTAssertEqual(value.frame, CGRect(x: 840, y: 300, width: 600, height: 600))
    }

    func testInvalidSavedFrameUsesCenteredDefaultAndRejectsInvalidScreens() {
        let value = SettingsWindowGeometry.placement(for: CGRect(x: CGFloat.nan, y: 0, width: 0, height: 0),
            visibleFrame: desktop, chromeHeight: 22)
        XCTAssertEqual(value.frame.size, CGSize(width: 570, height: 742))
        XCTAssertEqual(value.frame.midX, desktop.midX)
        XCTAssertEqual(value.frame.midY, desktop.midY)
        XCTAssertEqual(SettingsWindowGeometry.screenIndex(for: .zero, visibleFrames: [.zero, desktop],
            mouseLocation: .zero, mainIndex: 0), 1)
    }
}
