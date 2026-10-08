import AppKit

/// 直测捕获链路：ShotMark --capture-test
/// 完整起 NSApplication，didFinishLaunching 里抓一次主屏，打印真实错误后退出
final class CaptureTestDelegate: NSObject, NSApplicationDelegate {
    private func log(_ s: String) {
        fputs("[capture-test] \(s)\n", stderr)
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("shotmark-capture-test.log")
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(("[capture-test] \(s)\n").data(using: .utf8)!); try? h.close()
        } else {
            try? (("[capture-test] \(s)\n").data(using: .utf8)!).write(to: url)
        }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        log("preflight=\(CGPreflightScreenCaptureAccess()) bundle=\(Bundle.main.bundleIdentifier ?? "nil") path=\(Bundle.main.bundlePath)")
        if !CGPreflightScreenCaptureAccess() {
            log("requesting access（应弹出系统授权框）…")
            _ = CGRequestScreenCaptureAccess()
        }
        Task { @MainActor in
            let screens = NSScreen.screens
            self.log("screens=\(screens.count)")
            var ok = 0
            for s in screens {
                do {
                    let cg = try await Capture.grab(screen: s)
                    self.log("OK \(cg.width)x\(cg.height)")
                    ok += 1
                } catch {
                    self.log("FAIL: \(error)")
                }
            }
            self.log("done ok=\(ok)/\(screens.count)")
            NSApp.terminate(nil)
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // 无 Dock 图标，常驻后台

if CommandLine.arguments.contains("--capture-test") {
    app.delegate = CaptureTestDelegate()
} else {
    app.delegate = AppDelegate()
}
app.run()
