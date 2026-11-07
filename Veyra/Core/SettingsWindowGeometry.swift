import Foundation

/// Content sizes are in points; placement operates on the complete window frame.
enum SettingsWindowGeometry {
    static let defaultContentSize = CGSize(width: 570, height: 720)
    static let minimumContentSize = CGSize(width: 570, height: 440)

    static func isValid(_ rect: CGRect) -> Bool {
        [rect.origin.x, rect.origin.y, rect.width, rect.height].allSatisfy(\.isFinite)
            && rect.width > 0 && rect.height > 0
    }

    static func screenIndex(for frame: CGRect, visibleFrames: [CGRect],
                            screenFrames: [CGRect]? = nil,
                            mouseLocation: CGPoint, mainIndex: Int?) -> Int? {
        let valid = visibleFrames.indices.filter { isValid(visibleFrames[$0]) }
        if isValid(frame), let index = valid.max(by: {
            intersectionArea(frame, visibleFrames[$0]) < intersectionArea(frame, visibleFrames[$1])
        }), intersectionArea(frame, visibleFrames[index]) > 0 {
            return index
        }
        // Pointer selection includes menu bars and the Dock, unlike placement bounds.
        let pointerFrames = screenFrames.flatMap { $0.count == visibleFrames.count ? $0 : nil } ?? visibleFrames
        return valid.first(where: { pointerFrames[$0].contains(mouseLocation) })
            ?? mainIndex.flatMap { valid.contains($0) ? $0 : nil }
            ?? valid.first
    }

    static func placement(for frame: CGRect, visibleFrame: CGRect,
                          chromeHeight: CGFloat) -> (frame: CGRect, minimumContentSize: CGSize) {
        let chrome = chromeHeight.isFinite ? max(0, chromeHeight) : 0
        let minimum = CGSize(width: min(minimumContentSize.width, visibleFrame.width),
                             height: min(minimumContentSize.height, max(0, visibleFrame.height - chrome)))
        let fallbackSize = CGSize(width: defaultContentSize.width, height: defaultContentSize.height + chrome)
        let source = isValid(frame) ? frame : CGRect(
            x: visibleFrame.midX - fallbackSize.width / 2,
            y: visibleFrame.midY - fallbackSize.height / 2, width: fallbackSize.width, height: fallbackSize.height)
        let size = CGSize(width: min(visibleFrame.width, max(minimum.width, source.width)),
                          height: min(visibleFrame.height, max(minimum.height + chrome, source.height)))
        return (CGRect(x: min(max(source.minX, visibleFrame.minX), visibleFrame.maxX - size.width),
                       y: min(max(source.minY, visibleFrame.minY), visibleFrame.maxY - size.height),
                       width: size.width, height: size.height), minimum)
    }

    private static func intersectionArea(_ first: CGRect, _ second: CGRect) -> CGFloat {
        let intersection = first.intersection(second)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }
}
