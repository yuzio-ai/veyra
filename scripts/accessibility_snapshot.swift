import AppKit
import ApplicationServices
import Foundation

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}
// Read-only: no AXPress or AX attribute mutation, and no arbitrary app targets.
guard CommandLine.arguments.count == 5,
      let processID = Int32(CommandLine.arguments[1]), processID > 0,
      let application = NSRunningApplication(processIdentifier: processID),
      application.bundleIdentifier == "ai.yuzio.veyra",
      let bundleURL = application.bundleURL else {
    fail("Expected a running Veyra verification instance", code: 2)
}
let allowedPaths = CommandLine.arguments[3...4].map {
    URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
}
guard allowedPaths.contains(bundleURL.resolvingSymlinksInPath().path) else {
    fail("Target must be the fixed local verification app", code: 2)
}
guard AXIsProcessTrusted() else {
    fail("macOS Accessibility permission is required for this reader", code: 3)
}
@MainActor
func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
    return value
}
var nodes: [[String: Any]] = []
@MainActor
func visit(_ element: AXUIElement, depth: Int) {
    guard depth <= 24, nodes.count < 10000 else { return }
    var node: [String: Any] = ["depth": depth]
    for key in [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXIdentifierAttribute] {
        if let value = attribute(element, key), value is String || value is NSNumber { node[key] = value }
    }
    nodes.append(node)
    if let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
        for child in children { visit(child, depth: depth + 1) }
    }
}
let element = AXUIElementCreateApplication(processID)
guard attribute(element, kAXWindowsAttribute) != nil else {
    fail("Unable to read target accessibility windows", code: 4)
}
visit(element, depth: 0)
do {
    try JSONSerialization.data(withJSONObject: nodes, options: [.prettyPrinted, .sortedKeys])
        .write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
    print("Saved \(nodes.count) accessibility nodes")
} catch {
    fail("Unable to save accessibility snapshot", code: 5)
}
