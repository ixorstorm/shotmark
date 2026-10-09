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
    private var scrollSession: ScrollCaptureSession?
    private var toastWin: NSWindow?
    private var toastImage: NSImage?

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
        if scrollSession != nil { return }     // 滚动截屏进行中，忽略
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

    private func saveImage(_ img: NSImage, reveal: Bool = true) {
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
            if reveal { NSWorkspace.shared.activateFileViewerSelecting([url]) }
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
        win.isReleasedWhenClosed = false   // 默认 true：close 自释放 + 数组持有 = 双重释放崩溃
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

    func shotViewDidRequestScroll(_ view: ShotView, selection: CGRect) {
        guard let screen = view.window?.screen else { return }
        closeOverlays()
        let session = ScrollCaptureSession(screen: screen, regionPts: selection) { [weak self] img in
            guard let self = self else { return }
            self.scrollSession = nil
            guard let img = img else { return }   // 取消
            self.copyToPasteboard(img)
            let rep = img.representations.first
            // 不自动存盘（用户 2026-10-09：时间久了一大堆垃圾）——toast 上给「保存」按钮自选
            self.showToast("滚动截屏完成：已复制到剪贴板（\(rep?.pixelsWide ?? 0)×\(rep?.pixelsHigh ?? 0)px）", saveImage: img)
        }
        scrollSession = session
        session.start()
    }

    private func showToast(_ text: String, saveImage img: NSImage? = nil) {
        toastWin?.close()
        toastImage = img
        let w: CGFloat = 560, h: CGFloat = 44
        guard let screen = NSScreen.main else { return }
        let win = NSWindow(contentRect: NSRect(x: screen.frame.midX - w / 2,
                                               y: screen.frame.maxY - 110,
                                               width: w, height: h),
                           styleMask: .borderless, backing: .buffered, defer: false)
        win.level = .floating
        win.isOpaque = false
        win.backgroundColor = .clear
        win.isReleasedWhenClosed = false   // 同上，防双重释放
        let bg = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.92).cgColor
        bg.layer?.cornerRadius = 10
        let label = NSTextField(wrappingLabelWithString: text)
        label.alignment = .center
        label.textColor = .white
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        if img != nil {
            label.frame = NSRect(x: 12, y: 6, width: w - 96, height: h - 12)
            let btn = NSButton(title: "保存", target: self, action: #selector(toastSaveClicked))
            btn.bezelStyle = .rounded
            btn.frame = NSRect(x: w - 76, y: 8, width: 64, height: 28)
            bg.addSubview(btn)
        } else {
            label.frame = NSRect(x: 12, y: 6, width: w - 24, height: h - 12)
        }
        bg.addSubview(label)
        win.contentView = bg
        win.orderFrontRegardless()
        toastWin = win
        Timer.scheduledTimer(withTimeInterval: img != nil ? 6.0 : 3.0, repeats: false) { [weak self] _ in
            self?.toastWin?.close()
            self?.toastWin = nil
            self?.toastImage = nil
        }
    }

    @objc private func toastSaveClicked() {
        if let img = toastImage { saveImage(img, reveal: false) }
        toastWin?.close()
        toastWin = nil
        toastImage = nil
    }
}
