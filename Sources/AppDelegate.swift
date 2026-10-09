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
        Capture.warm()   // 后台预热 SCK 管线 + 内容清单缓存
        let hotkeyOK = HotKey.register()
        HotKey.onFire = { [weak self] in self?.startCapture() }
        if !hotkeyOK {
            statusItem?.button?.title = "⚠️"
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
                if let ov = self?.overlays.first, let view = ov.contentView as? ShotView {
                    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("shotmark-overlay-test.png")
                    Render.writePNG(view.captured, to: url)
                    log("saved -> \(url.path) size=\(view.captured.size)")
                } else {
                    log("NO OVERLAY")
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
        if scrollSession != nil { return }     // 滚动截屏进行中，忽略
        if !overlays.isEmpty {           // 已有覆盖层 = 再按一次热键关闭
            closeOverlays()
            return
        }
        // 锁屏时 SCK 只能抓到壁纸（锁屏盖住所有窗口是 macOS 隐私设计）——直接不弹
        if let d = CGSessionCopyCurrentDictionary() as? [String: Any],
           (d["CGSSessionScreenIsLocked"] as? Bool) == true {
            fputs("[ShotMark] 屏幕已锁定，跳过截图（锁屏下只能抓到壁纸）\n", stderr)
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
            // 双屏并行抓（串行时清单一拉两遍 + 逐屏等待，~210ms；并行后 ≈ 单屏耗时）。
            // ⚠️ 屏→显示器映射必须在主线程先解析好：NSScreen.deviceDescription 跨线程读不可靠
            //（实测事故：并行任务里读它导致外屏装上了内屏的图——「按热键就只剩背景」）
            var results: [Int: CGImage] = [:]
            let jobs: [(Int, CGDirectDisplayID)] = screens.enumerated().compactMap { (i, screen) in
                guard let did = Capture.displayID(for: screen) else { return nil }
                fputs("[ShotMark] 映射: screen[\(i)] frame=\(screen.frame.size) id=\(did)\n", stderr)
                return (i, did)
            }
            await withTaskGroup(of: (Int, CGImage?, NSError?).self) { group in
                for (i, did) in jobs {
                    group.addTask {
                        do { return (i, try await Capture.grab(displayID: did), nil) }
                        catch { return (i, nil, error as NSError) }
                    }
                }
                for await (i, cg, err) in group {
                    if let cg = cg { results[i] = cg }
                    if let err = err {
                        fputs("[ShotMark] 捕获失败: \(err.domain) \(err.code) \(err.localizedDescription)\n", stderr)
                        if err.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain", err.code == -3801 { tccDenied = true }
                        if firstError.isEmpty { firstError = "\(err.code) \(err.localizedDescription)" }
                    }
                }
            }
            for (i, screen) in screens.enumerated() {
                if let cg = results[i] {
                    fputs("[ShotMark] 覆盖层: screen[\(i)] \(screen.frame.size) <- 图 \(cg.width)x\(cg.height)\n", stderr)
                    presentOverlay(screen: screen, image: NSImage(cgImage: cg, size: screen.frame.size))
                    ok = true
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
