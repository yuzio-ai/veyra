import AppKit

/// Isolated UI-test application. It lends activation permission without opening
/// the menu or sending Escape; those actions still use the production controller.
@MainActor
final class KeyboardFocusFixtureHost: NSObject, NSApplicationDelegate {
    private let directory: URL
    private var window: NSWindow?
    private var timer: Timer?
    private var lastRequest: String?
    private var observedRequest: String?
    private var announcedReady = false
    private var readinessTicks = 0
    private var stableReadinessTicks = 0
    private var stableRequestTicks = 0

    init(directory: URL) { self.directory = directory }

    func applicationDidBecomeActive(_ notification: Notification) { traceState("became active") }
    func applicationDidResignActive(_ notification: Notification) { traceState("resigned active") }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 90),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Veyra keyboard fixture"
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.center(); window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate()
        traceState("launched")
        timer = Timer.scheduledTimer(timeInterval: 0.05, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
    }

    @objc private func tick() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--preview-lease"), arguments.indices.contains(index + 1),
              (try? String(contentsOf: directory.appendingPathComponent("active-lease"), encoding: .utf8)) == arguments[index + 1] else {
            timer?.invalidate(); NSApp.terminate(nil); return
        }
        if !announcedReady {
            readinessTicks += 1
            if readinessTicks.isMultiple(of: 20) { traceState("awaiting activation") }
            if !isFrontmost { requestActivation() }
            stableReadinessTicks = isFrontmost && window?.isKeyWindow == true ? stableReadinessTicks + 1 : 0
            if stableReadinessTicks >= 3 {
                do {
                    try arguments[index + 1].write(to: directory.appendingPathComponent("host-ready"), atomically: true, encoding: .utf8)
                    announcedReady = true
                } catch { timer?.invalidate(); NSApp.terminate(nil); return }
            }
        }
        let parent = directory.deletingLastPathComponent()
        guard let request = try? String(contentsOf: parent.appendingPathComponent("focus-request"), encoding: .utf8),
              request != lastRequest else { return }
        if request != observedRequest {
            trace("request: active=\(NSApp.isActive), key=\(window?.isKeyWindow == true), front=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown")")
            observedRequest = request
            stableRequestTicks = 0
            // Finish this activation before yielding. A later activation call
            // would cancel the permission just granted to the menu application.
        }
        if !isFrontmost { requestActivation() }
        stableRequestTicks = isFrontmost ? stableRequestTicks + 1 : 0
        // The host is only a foreground baseline and receives no keyboard
        // events. AppKit may leave its window non-key after restoring the app;
        // the menu under test must independently prove active/key focus.
        guard stableRequestTicks >= 3 else { return }
        guard let data = try? Data(contentsOf: parent.appendingPathComponent("process.json")),
              let receipt = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              receipt["token"] as? String == arguments[index + 1],
              let rawPID = receipt["pid"] as? Int, let target = NSRunningApplication(processIdentifier: pid_t(rawPID)) else {
            trace("parent identity unavailable after settled focus")
            return
        }
        NSApp.yieldActivation(to: target)
        trace("yielded to parent \(target.processIdentifier): active=true, key=\(window?.isKeyWindow == true)")
        do {
            try request.write(to: parent.appendingPathComponent("focus-ready"), atomically: true, encoding: .utf8)
            lastRequest = request
        } catch { timer?.invalidate(); NSApp.terminate(nil) }
    }

    private var isFrontmost: Bool {
        NSApp.isActive
            && NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
    }

    private func requestActivation() {
        window?.makeKeyAndOrderFront(nil)
        if !NSApp.isActive { NSApp.activate() }
    }

    private func trace(_ message: String) {
        FileHandle.standardOutput.write(Data("Focus host \(ProcessInfo.processInfo.systemUptime): \(message)\n".utf8))
    }

    private func traceState(_ phase: String) {
        let front = NSWorkspace.shared.frontmostApplication
        trace("\(phase): active=\(NSApp.isActive), key=\(window?.isKeyWindow == true), policy=\(NSApp.activationPolicy().rawValue), canKey=\(window?.canBecomeKey == true), visible=\(window?.isVisible == true), onActiveSpace=\(window?.isOnActiveSpace == true), hidden=\(NSApp.isHidden), frontIsSelf=\(front?.processIdentifier == ProcessInfo.processInfo.processIdentifier), frontPresent=\(front != nil)")
    }
}
