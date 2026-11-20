import AppKit
import CoreGraphics

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    private func logWindow(_ event: String) {
        AppLog.event(event, ["windowNumber": windowNumber, "frame": NSStringFromRect(frame),
                             "level": level.rawValue, "visible": isVisible, "key": isKeyWindow,
                             "canBecomeKey": canBecomeKey])
    }
    override func becomeKey() { super.becomeKey(); logWindow("window_become_key") }
    override func resignKey() { super.resignKey(); logWindow("window_resign_key") }
    override func becomeMain() { super.becomeMain(); logWindow("window_become_main") }
    override func resignMain() { super.resignMain(); logWindow("window_resign_main") }
    override func close() { logWindow("window_close"); super.close() }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var overlays: [OverlayWindow] = []
    private var pinnedWindows: [NSWindow] = []
    private var statusItem: NSStatusItem?
    private var scrollSession: ScrollCaptureSession?
    private var toastWin: NSWindow?
    private var toastImage: NSImage?
    private var eventMonitors: [Any] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLog.event("did_finish_launching")
        installEventMonitors()
        setupStatusItem()
        Capture.warm()   // 后台预热 SCK 管线 + 内容清单缓存
        let hotkeyOK = HotKey.register()
        AppLog.event("startup", ["hotkeyOK": hotkeyOK, "capturePreflight": CGPreflightScreenCaptureAccess(),
                                 "screens": NSScreen.screens.count])
        HotKey.onFire = { [weak self] in self?.startCapture() }
        if !hotkeyOK {
            statusItem?.button?.title = "⚠️"
        }

        if CommandLine.arguments.contains("--ocr-test") {
            // 面板冒烟：弹「识别中…」→ 1s 后填示例结果（真识别走 --selftest 的 testOCR）
            guard let screen = NSScreen.main else { return }
            OCRPanelController.shared.show(on: screen)
            OCRPanelController.shared.setLoading()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                OCRPanelController.shared.setResult("面板冒烟测试：这行字应该出现在可编辑的文本框里。\n第二行。")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { NSApp.terminate(nil) }
            return
        }

        if CommandLine.arguments.contains("--toast-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.showToast("滚动截屏完成：已复制到剪贴板（3160×8920px）", saveImage: NSImage(size: NSSize(width: 10, height: 10)))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) { NSApp.terminate(nil) }
            return
        }

        if CommandLine.arguments.contains("--overlay-test") {
            // 完整走热键路径（并行抓图 + 覆盖层），把抓到的图落盘后退出
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.startCapture() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
                let logURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("shotmark-capture-test.log")
                func log(_ s: String) {
                    fputs("[overlay-test] \(s)\n", stderr)
                    if let h = try? FileHandle(forWritingTo: logURL) {
                        h.seekToEndOfFile(); h.write(("[overlay-test] \(s)\n").data(using: .utf8)!); try? h.close()
                    } else { try? ("[overlay-test] \(s)\n".data(using: .utf8)!).write(to: logURL) }
                }
                guard let ovs = self?.overlays, !ovs.isEmpty else { log("NO OVERLAY"); NSApp.terminate(nil); return }
                for (i, ov) in ovs.enumerated() {
                    guard let view = ov.contentView as? ShotView else { continue }
                    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("shotmark-overlay-\(i).png")
                    Render.writePNG(view.captured, to: url)
                    let rep = view.captured.representations.first
                    log("overlay[\(i)] frame=\(ov.frame) img=\(rep?.pixelsWide ?? 0)x\(rep?.pixelsHigh ?? 0) -> \(url.lastPathComponent)")
                }
                NSApp.terminate(nil)
            }
            return
        }

        if SelfTest.enabled {
            SelfTest.run()
            if SelfTest.liveEnabled {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { NSApp.terminate(nil) }  // 等真机冒烟跑完
            } else {
                NSApp.terminate(nil)
            }
            return
        }
    }

    // MARK: - 截图入口

    @objc func startCapture() {
        AppLog.event("capture_request", ["scrollActive": scrollSession != nil, "overlayCount": overlays.count])
        if scrollSession != nil {
            AppLog.event("capture_ignored", ["reason": "scroll_active"])
            return
        }
        if !overlays.isEmpty {           // 已有覆盖层 = 再按一次热键关闭
            AppLog.event("capture_toggle_close")
            closeOverlays()
            return
        }
        // 锁屏时 SCK 只能抓到壁纸（锁屏盖住所有窗口是 macOS 隐私设计）——直接不弹
        if let d = CGSessionCopyCurrentDictionary() as? [String: Any],
           (d["CGSSessionScreenIsLocked"] as? Bool) == true {
            AppLog.event("capture_ignored", ["reason": "screen_locked"])
            fputs("[ShotMark] 屏幕已锁定，跳过截图（锁屏下只能抓到壁纸）\n", stderr)
            return
        }
        guard CGPreflightScreenCaptureAccess() else {
            AppLog.event("capture_permission_missing")
            CGRequestScreenCaptureAccess()
            alert("需要「屏幕录制」权限",
                  "在 系统设置 → 隐私与安全性 → 屏幕录制与系统录音 中勾选 ShotMark，然后重新打开 ShotMark 再按 ⌃⇧A。")
            return
        }
        // 目标屏 = 鼠标所在屏（飞书/CleanShot 同款口径；NSEvent.mouseLocation 后台也可读）。
        // 参照：https://stackoverflow.com/questions/49624486/49624487
        // 单屏单抓单覆盖层——多屏双抓被 SCK 并发换结果坑过（外屏拿回内屏像素），不再并行
        let screens = NSScreen.screens
        let mouseLoc = NSEvent.mouseLocation
        let target = screens.first { NSMouseInRect(mouseLoc, $0.frame, false) } ?? NSScreen.main ?? screens[0]
        AppLog.event("capture_target", ["screen": NSStringFromRect(target.frame), "screenCount": screens.count])
        fputs("[ShotMark] 目标屏: 鼠标(\(Int(mouseLoc.x)),\(Int(mouseLoc.y))) -> \(target.frame)\n", stderr)
        Task { @MainActor in
            guard let did = Capture.displayID(for: target) else {
                alert("截图失败", "未能解析目标屏幕。")
                return
            }
            // 启动台/调度中心检测：它们由 Dock 渲染在独立合成平面，SCK 抓不到
            //（抓到的是底下桌面，用户会误以为截到了——「截出来是空的」事故 2026-10-12）。
            // 检测口径待校准：先把现场打进日志（frontmost + Dock 全屏窗），命中就拦。
            if let content = try? await Capture.content() {
                let dockWins = content.windows.filter {
                    $0.owningApplication?.bundleIdentifier == "com.apple.dock" && $0.isOnScreen
                }
                let front = NSWorkspace.shared.frontmostApplication
                fputs("[ShotMark] 现场: frontmost=\(front?.bundleIdentifier ?? "?") dockOnScreen=\(dockWins.map { "\(($0.title ?? "").isEmpty ? "无题" : ($0.title ?? "")) \(Int($0.frame.width))x\(Int($0.frame.height))" })\n", stderr)
                let dockFullscreen = dockWins.contains {
                    ($0.title ?? "").isEmpty && $0.frame.width >= target.frame.width * 0.9 && $0.frame.height >= target.frame.height * 0.9
                }
                if dockFullscreen {
                    // 只记日志不拦截（10-12 翻案：Tahoe 的「应用程序」其实抓得到，白图是导出变换的锅）
                    fputs("[ShotMark] 注意：检测到 Dock 全屏界面（可能启动台/调度中心），照常截\n", stderr)
                }
            }
            do {
                let cg = try await Capture.grab(displayID: did)
                AppLog.event("capture_ok", ["width": cg.width, "height": cg.height, "screen": NSStringFromRect(target.frame)])
                fputs("[ShotMark] 覆盖层: \(target.frame.size) <- 图 \(cg.width)x\(cg.height)\n", stderr)
                NSApp.setActivationPolicy(.regular)
                AppLog.event("activation_policy_regular")
                presentOverlay(screen: target, image: NSImage(cgImage: cg, size: target.frame.size))
                NSApp.activate(ignoringOtherApps: true)
                AppLog.event("activate_after_overlay")
            } catch {
                let nserr = error as NSError
                AppLog.event("capture_error", ["domain": nserr.domain, "code": nserr.code, "message": nserr.localizedDescription])
                fputs("[ShotMark] 捕获失败: \(nserr.domain) \(nserr.code) \(nserr.localizedDescription)\n", stderr)
                if nserr.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain", nserr.code == -3801 {
                    alert("屏幕录制权限未生效",
                          "系统已记录授权，但当前进程还没生效。请点菜单栏取景器图标 →「退出 ShotMark」，再重新打开，然后按 ⌃⇧A。")
                } else {
                    alert("截图失败", "未能获得屏幕内容（\(nserr.code) \(nserr.localizedDescription)）。请检查屏幕录制权限后重试。")
                }
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
        AppLog.event("overlay_before_show", ["windowNumber": win.windowNumber, "frame": NSStringFromRect(win.frame),
                                              "level": win.level.rawValue, "canBecomeKey": win.canBecomeKey])
        win.makeKeyAndOrderFront(nil)
        overlays.append(win)
        AppLog.event("overlay_after_show", ["windowNumber": win.windowNumber, "visible": win.isVisible,
                                             "key": win.isKeyWindow, "firstResponder": win.firstResponder.map { String(describing: type(of: $0)) } ?? "nil",
                                             "viewFirstResponder": win.firstResponder === view])
    }

    private func closeOverlays() {
        AppLog.event("overlay_close_begin", ["count": overlays.count])
        for w in overlays { w.close() }
        overlays.removeAll()
        OCRPanelController.shared.close()   // 截图状态收起，OCR 面板跟着收（二者共存、共退）
        NSApp.setActivationPolicy(.accessory)   // 收完回到无 Dock 常驻
        AppLog.event("overlay_close_end")
    }

    // MARK: - 完成动作

    private func copyToPasteboard(_ img: NSImage) {
        AppLog.event("pasteboard_copy_begin", ["image": String(describing: img.size)])
        let pb = NSPasteboard.general
        pb.clearContents()
        // PNG 必须显式放：writeObjects([NSImage]) 只给 TIFF，而 UTM/SPICE 剪贴板同步、
        // Windows/Linux 端、多数虚拟机都认 public.png（macOS 原生 ⇧⌃⌘4 进剪贴板的就是 PNG）
        if let png = Render.pngData(of: img) {
            pb.setData(png, forType: .png)
        }
        if let tiff = img.tiffRepresentation {
            pb.setData(tiff, forType: .tiff)
        }
        AppLog.event("pasteboard_copy_end", ["changeCount": pb.changeCount, "types": pb.types?.map { $0.rawValue } ?? []])
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

    // MARK: - 应用事件与本地输入取证

    func applicationDidBecomeActive(_ notification: Notification) { AppLog.event("app_did_become_active") }
    func applicationDidResignActive(_ notification: Notification) { AppLog.event("app_did_resign_active") }
    func applicationWillTerminate(_ notification: Notification) { AppLog.event("app_will_terminate") }

    private func installEventMonitors() {
        let specs: [(NSEvent.EventTypeMask, String)] = [
            (.leftMouseDown, "local_mouse_down"), (.leftMouseUp, "local_mouse_up"),
            (.rightMouseDown, "local_right_mouse_down"), (.keyDown, "local_key_down"),
        ]
        for (mask, name) in specs {
            if let token = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { ev in
                AppLog.event(name, ["keyCode": ev.keyCode, "clickCount": ev.clickCount,
                                    "windowNumber": ev.windowNumber,
                                    "location": NSStringFromPoint(ev.locationInWindow)])
                return ev
            }) { eventMonitors.append(token) }
        }
        AppLog.event("event_monitors_installed", ["count": eventMonitors.count])
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
    func shotView(_ view: ShotView, didFinish image: NSImage?, action: FinishAction?, blank: Bool = false) {
        AppLog.event("shot_finish_received", ["action": action.map { String(describing: $0) } ?? "nil",
                                               "hasImage": image != nil, "blank": blank, "overlayCount": overlays.count])
        if blank {
            // 白板导出：不静默出白图——toast 提示重试，现场已落盘 $TMPDIR/shotmark-last-*.png
            fputs("[ShotMark] ⚠️ 导出白板，action=\(String(describing: action))\n", stderr)
            showToast("截图内容异常（空白），请重试")
            return
        }
        // OCR 期间保留覆盖层（飞书同款：暗色截图状态 + 文字面板同时显示，截图不准可重新框选）
        if action != .ocr { closeOverlays() }
        guard let img = image, let action = action else { return }
        switch action {
        case .copy:
            AppLog.event("finish_action", ["action": "copy"])
            copyToPasteboard(img)
        case .save:
            AppLog.event("finish_action", ["action": "save"])
            saveImage(img)
        case .pin:
            AppLog.event("finish_action", ["action": "pin"])
            pinImage(img)
        case .ocr:
            // 飞书同款：立即弹「识别中…」面板，结果可查看/编辑，用户点「复制文本」才进剪贴板
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
            if let screen = screen {
                OCRPanelController.shared.show(on: screen)
                OCRPanelController.shared.setLoading()
            }
            Task { @MainActor in
                let text = await OCR.recognize(img)
                OCRPanelController.shared.setResult(text ?? "")
            }
        }
    }

    func shotViewDidRequestScroll(_ view: ShotView, selection: CGRect) {
        guard let screen = view.window?.screen else { return }
        closeOverlays()
        let session = ScrollCaptureSession(screen: screen, regionPts: selection, snapshot: view.captured) { [weak self] img in
            guard let self = self else { return }
            self.scrollSession = nil
            guard let img = img else { return }   // 取消
            self.copyToPasteboard(img)
            let rep = img.representations.first
            self.showToast("长截图完成：已复制到剪贴板（\(rep?.pixelsWide ?? 0)×\(rep?.pixelsHigh ?? 0)px）", saveImage: img)
        }
        scrollSession = session
        // 飞书方案：用户自己滚动，工具定时抓帧拼接（不替用户滚动，不发合成滚轮事件）
        session.start()
    }

    private func showToast(_ text: String, saveImage img: NSImage? = nil) {
        toastWin?.close()
        toastImage = img
        guard let screen = NSScreen.main else { return }
        // 按文字实测尺寸排版：label 水平垂直居中，「保存」按钮在右不占文字的中线
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let ts = NSString(string: text).size(withAttributes: [.font: font])
        let labelW = ceil(ts.width), labelH = ceil(ts.height)
        let pad: CGFloat = 16, gap: CGFloat = 10, btnW: CGFloat = 64, btnH: CGFloat = 26
        let w = pad * 2 + labelW + (img != nil ? gap + btnW : 0)
        let h = max(44, labelH + 22)
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
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = .white
        label.alignment = .center
        label.frame = NSRect(x: pad, y: (h - labelH) / 2 - 1, width: labelW, height: labelH + 2)
        bg.addSubview(label)
        if img != nil {
            let btn = NSButton(title: "保存", target: self, action: #selector(toastSaveClicked))
            btn.bezelStyle = .rounded
            btn.frame = NSRect(x: pad + labelW + gap, y: (h - btnH) / 2, width: btnW, height: btnH)
            bg.addSubview(btn)
        }
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
