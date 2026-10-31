import AppKit

/// Isolated UI-test application. It lends activation permission without opening
/// the menu or sending Escape; those actions still use the production controller.
@MainActor
final class KeyboardFocusFixtureHost: NSObject, NSApplicationDelegate {
    private let directory: URL
    private var window: NSWindow?
    private var timer: Timer?
    private var lastRequest: String?
    private var announcedReady = false

    init(directory: URL) { self.directory = directory }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 90),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Veyra keyboard fixture"
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.center(); window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate()
        print("Focus host launched: active=\(NSApp.isActive), policy=\(NSApp.activationPolicy().rawValue)")
        timer = Timer.scheduledTimer(timeInterval: 0.05, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
    }

    @objc private func tick() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--preview-lease"), arguments.indices.contains(index + 1),
              (try? String(contentsOf: directory.appendingPathComponent("active-lease"), encoding: .utf8)) == arguments[index + 1] else {
            timer?.invalidate(); NSApp.terminate(nil); return
        }
        if !announcedReady, NSApp.isActive, window?.isKeyWindow == true {
            do {
                try arguments[index + 1].write(to: directory.appendingPathComponent("host-ready"), atomically: true, encoding: .utf8)
                announcedReady = true
            } catch { timer?.invalidate(); NSApp.terminate(nil); return }
        }
        let parent = directory.deletingLastPathComponent()
        guard NSApp.isActive,
              let request = try? String(contentsOf: parent.appendingPathComponent("focus-request"), encoding: .utf8), request != lastRequest,
              let data = try? Data(contentsOf: parent.appendingPathComponent("process.json")),
              let receipt = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              receipt["token"] as? String == arguments[index + 1],
              let rawPID = receipt["pid"] as? Int, let target = NSRunningApplication(processIdentifier: pid_t(rawPID)) else { return }
        NSApp.yieldActivation(to: target)
        print("Focus host yielded to parent \(target.processIdentifier)")
        do {
            try request.write(to: parent.appendingPathComponent("focus-ready"), atomically: true, encoding: .utf8)
            lastRequest = request
        } catch { timer?.invalidate(); NSApp.terminate(nil) }
    }
}
