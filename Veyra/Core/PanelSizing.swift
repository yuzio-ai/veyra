import Foundation

/// Screen inputs are injectable so layout tests never depend on the test machine.
struct PanelScreenMetrics: Equatable, Sendable {
    var visibleHeight: CGFloat
    var windowChromeHeight: CGFloat = 0

    var maximumPanelHeight: CGFloat {
        max(0, floor(visibleHeight - max(0, windowChromeHeight) - 24))
    }
}

/// Only the middle viewport is capped. There is deliberately no minimum content height.
struct PanelSizing: Equatable, Sendable {
    static let width: CGFloat = 360

    var contentHeight: CGFloat
    var headerHeight: CGFloat
    var footerHeight: CGFloat
    var screen: PanelScreenMetrics

    var viewportHeight: CGFloat {
        min(max(0, contentHeight), max(0, screen.maximumPanelHeight - headerHeight - footerHeight))
    }

    var panelHeight: CGFloat { headerHeight + viewportHeight + footerHeight }
    var isScrollable: Bool { contentHeight > viewportHeight }
}
