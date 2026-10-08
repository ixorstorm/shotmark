import AppKit
import CoreGraphics

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var overlays: [OverlayWindow] = []
    private var pinnedWindows: [NSWindow] = []
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        let hotkeyOK = HotKey.register()
        HotKey.onFire = { [weak self] in self?.startCapture() }
        if !hotkeyOK {
            statusItem?.button?.title = "⚠️"
        }

        if SelfTest.enabled {
            SelfTest.run()
            NSApp.terminate(nil)
            return
        }
    }

    // MARK: - 截图入口

    @objc func startCapture() {
        if !overlays.isEmpty {           // 已有覆盖层 = 再按一次热键关闭
            closeOverlays()
            return
        }
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            alert("需要「屏幕录制」权限",
                  "在 系统设置 → 隐私与安全性 → 屏幕录制与系统录音 中勾选 ShotMark，然后重新打开 ShotMark 再按 ⌃⇧A。")
            return
        }
        let screens = NSScreen.screens
        Task { @MainActor in
            var ok = false
            var tccDenied = false
            var firstError = ""
            for screen in screens {
                do {
                    let cg = try await Capture.grab(screen: screen)
                    let img = NSImage(cgImage: cg, size: screen.frame.size)
                    presentOverlay(screen: screen, image: img)
                    ok = true
                } catch {
                    let nserr = error as NSError
                    fputs("[ShotMark] 捕获失败: \(nserr.domain) \(nserr.code) \(nserr.localizedDescription)\n", stderr)
                    if nserr.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain", nserr.code == -3801 {
                        tccDenied = true
                    }
                    if firstError.isEmpty { firstError = "\(nserr.code) \(nserr.localizedDescription)" }
                }
            }
            if ok {
                NSApp.activate(ignoringOtherApps: true)
            } else if tccDenied {
                alert("屏幕录制权限未生效",
                      "系统已记录授权，但当前进程还没生效。请点菜单栏取景器图标 →「退出 ShotMark」，再重新打开，然后按 ⌃⇧A。")
            } else {
                alert("截图失败", "未能获得屏幕内容（\(firstError)）。请检查屏幕录制权限后重试。")
            }
        }
    }

    private func presentOverlay(screen: NSScreen, image: NSImage) {
        let win = OverlayWindow(contentRect: screen.frame, styleMask: .borderless,
                                backing: .buffered, defer: false)
        win.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.acceptsMouseMovedEvents = true
        win.isReleasedWhenClosed = false
        let view = ShotView(frame: NSRect(origin: .zero, size: screen.frame.size), captured: image)
        view.delegate = self
        win.contentView = view
        win.makeKeyAndOrderFront(nil)
        overlays.append(win)
    }

    private func closeOverlays() {
        for w in overlays { w.close() }
        overlays.removeAll()
    }

    // MARK: - 完成动作

    private func copyToPasteboard(_ img: NSImage) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([img])
    }

    private func saveImage(_ img: NSImage) {
        guard let data = Render.pngData(of: img) else { return }
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures/ShotMark", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        var url = dir.appendingPathComponent("ShotMark-\(fmt.string(from: Date())).png")
        var n = 1
        while FileManager.default.fileExists(atPath: url.path) {
            n += 1
            url = dir.appendingPathComponent("ShotMark-\(fmt.string(from: Date()))-\(n).png")
        }
        do {
            try data.write(to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            alert("保存失败", error.localizedDescription)
        }
    }

    private func pinImage(_ img: NSImage) {
        let size = img.size
        let win = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                           styleMask: [.titled, .closable, .resizable, .miniaturizable],
                           backing: .buffered, defer: false)
        win.title = "ShotMark 钉图"
        let iv = NSImageView(image: img)
        iv.imageScaling = .scaleProportionallyUpOrDown
        win.contentView = iv
        win.level = .floating
        win.center()
        win.makeKeyAndOrderFront(nil)
        pinnedWindows.append(win)
    }

    // MARK: - 状态栏

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button,
           let img = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "ShotMark") {
            img.isTemplate = true
            button.image = img
        }
        let menu = NSMenu()
        let shot = menu.addItem(withTitle: "截图（⌃⇧A）", action: #selector(menuCapture(_:)), keyEquivalent: "")
        shot.target = self
        menu.addItem(.separator())
        let open = menu.addItem(withTitle: "打开保存目录", action: #selector(openSaveDir(_:)), keyEquivalent: "")
        open.target = self
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "退出 ShotMark", action: #selector(quitApp(_:)), keyEquivalent: "q")
        quit.target = self
        statusItem?.menu = menu
    }

    @objc private func menuCapture(_ sender: Any?) { startCapture() }

    @objc private func openSaveDir(_ sender: Any?) {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures/ShotMark", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    @objc private func quitApp(_ sender: Any?) { NSApp.terminate(nil) }

    // MARK: - 工具

    private func alert(_ title: String, _ msg: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = msg
        a.addButton(withTitle: "好")
        a.runModal()
    }
}

extension AppDelegate: ShotViewDelegate {
    func shotView(_ view: ShotView, didFinish image: NSImage?, action: FinishAction?) {
        closeOverlays()
        guard let img = image, let action = action else { return }
        switch action {
        case .copy: copyToPasteboard(img)
        case .save: saveImage(img)
        case .pin:  pinImage(img)
        }
    }
}
