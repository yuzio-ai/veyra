import XCTest
import Foundation

final class PanelSizingTests: XCTestCase {
    private func sizing(_ content: CGFloat, visible: CGFloat = 900, chrome: CGFloat = 0) -> PanelSizing {
        PanelSizing(contentHeight: content, headerHeight: 62, footerHeight: 56,
                    screen: PanelScreenMetrics(visibleHeight: visible, windowChromeHeight: chrome))
    }

    func testShortContentUsesNaturalHeightWithoutMinimumOrBlankSpace() {
        let value = sizing(140)
        XCTAssertEqual(value.viewportHeight, 140)
        XCTAssertEqual(value.panelHeight, 258)
        XCTAssertFalse(value.isScrollable)
        XCTAssertEqual(PanelSizing.width, 360)
    }

    func testOverflowOnlyCapsViewportAndAccountsForWindowChrome() {
        let value = sizing(2_000, visible: 800, chrome: 22)
        XCTAssertEqual(value.viewportHeight, 636)
        XCTAssertEqual(value.panelHeight, 754)
        XCTAssertTrue(value.isScrollable)
    }

    func testExactFitDoesNotScroll() {
        let value = sizing(758)
        XCTAssertEqual(value.panelHeight, 876)
        XCTAssertFalse(value.isScrollable)
    }

    func testDisclosureGrowsThenCapsAndShrinksAgain() {
        var value = sizing(260)
        XCTAssertEqual(value.viewportHeight, 260)
        value.contentHeight = 480
        XCTAssertEqual(value.viewportHeight, 480)
        XCTAssertFalse(value.isScrollable)
        value.contentHeight = 960
        XCTAssertEqual(value.viewportHeight, 758)
        XCTAssertTrue(value.isScrollable)
        value.contentHeight = 260
        XCTAssertEqual(value.panelHeight, 378)
        XCTAssertFalse(value.isScrollable)
    }

    func testMovingBetweenScreensRecomputesTheCap() {
        var value = sizing(700, visible: 1_000)
        XCTAssertFalse(value.isScrollable)
        value.screen = PanelScreenMetrics(visibleHeight: 600)
        XCTAssertEqual(value.viewportHeight, 458)
        XCTAssertTrue(value.isScrollable)
        value.screen = PanelScreenMetrics(visibleHeight: 1_000)
        XCTAssertEqual(value.viewportHeight, 700)
        XCTAssertFalse(value.isScrollable)
    }

    func testHeaderAndFooterAreMeasuredRatherThanHardCoded() {
        var value = sizing(1_000)
        value.headerHeight += 20
        value.footerHeight += 12
        XCTAssertEqual(value.viewportHeight, 726)
        XCTAssertEqual(value.panelHeight, 876)
    }

    func testEmptyAndVerySmallScreensNeverProduceNegativeViewport() {
        XCTAssertEqual(sizing(0).viewportHeight, 0)
        XCTAssertFalse(sizing(0).isScrollable)
        XCTAssertEqual(sizing(100, visible: 100).viewportHeight, 0)
        XCTAssertEqual(PanelScreenMetrics(visibleHeight: 10, windowChromeHeight: 22).maximumPanelHeight, 0)
    }

    func testFractionalAvailableHeightRoundsDownToStayOnScreen() {
        XCTAssertEqual(sizing(2_000, visible: 800.75, chrome: 22.5).panelHeight, 754)
    }
}
