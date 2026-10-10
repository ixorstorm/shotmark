import AppKit

/// 自检模式：`ShotMark --selftest`
/// 不碰真实屏幕（无需屏幕录制权限），生成假底图 + 各类型标注，
/// 输出两张 PNG：导出国（裁剪+标注）与完整界面图（蒙层/工具栏/手柄）。
enum SelfTest {

    static var enabled: Bool { CommandLine.arguments.contains("--selftest") }
    static var liveEnabled: Bool { CommandLine.arguments.contains("--selftest-live") }

    static func run() {
        let outDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("shotmark-selftest")
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let captured = fakeScreenshot()
        let sel = NSRect(x: 220, y: 170, width: 760, height: 440)
        let anns = demoAnnotations()

        // 1) 导出国
        if let out = Render.export(captured: captured, selection: sel, annotations: anns) {
            let url = outDir.appendingPathComponent("export.png")
            Render.writePNG(out, to: url)
            print("export -> \(url.path)  size=\(out.size.width)x\(out.size.height)pt")
        } else {
            print("export FAILED")
        }

        // 2) 完整界面图（走 ShotView.draw 全路径：蒙层/选区/标注/工具栏）
        let view = ShotView(frame: NSRect(origin: .zero, size: captured.size), captured: captured)
        view.selection = sel
        view.annotations = anns
        view.tool = .ellipse
        // 选中态自检：第一个标注（椭圆）显示虚线框 + 四角手柄
        view.selectedAnn = 0
        // 悬停 tip 自检：在椭圆按钮上方画「椭圆」小药丸
        view.hoverTipText = "椭圆"
        view.hoverBtnRect = CGRect(x: sel.midX, y: sel.minY - 44, width: 30, height: 28)
        view.hoverTipVisible = true
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                let url = outDir.appendingPathComponent("view.png")
                try? data.write(to: url)
                print("view   -> \(url.path)")
            }
        }

        // 3) 滚动拼接离线自检
        testScrollStitch(outDir: outDir)
        testWhitePageMatching(outDir: outDir)
        testReanchor()
        testDimLayer(captured: captured, sel: sel, outDir: outDir)
        testPasteboardTypes()
        testAnnotationTransforms()
        testTextPipeline(captured: captured, sel: sel, outDir: outDir)
        testExportRegion(captured: captured, sel: sel, outDir: outDir)
        testAnnotationTapRules(captured: captured)
        if CommandLine.arguments.contains("--selftest-live") { testLiveSession() }
    }

    /// 剪贴板类型自检：写入的图必须同时含 public.png（虚拟机/UTM 认这个）+ public.tiff
    /// 用独立 scratch pasteboard，不碰用户的通用剪贴板
    private static func testPasteboardTypes() {
        let img = NSImage(size: NSSize(width: 8, height: 8))
        img.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        img.unlockFocus()
        let pb = NSPasteboard(name: NSPasteboard.Name("shotmark-selftest"))
        pb.clearContents()
        if let png = Render.pngData(of: img) { pb.setData(png, forType: .png) }
        if let tiff = img.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
        let types = pb.types ?? []
        let hasPNG = types.contains(.png)
        let hasTIFF = types.contains(.tiff)
        print("pasteboard: png=\(hasPNG) tiff=\(hasTIFF) -> \(hasPNG && hasTIFF ? "PASS" : "FAIL")")
    }

    /// 点按判定自检（用户事故 2026-10-10「圈内打字没创建文字」）：
    /// 空心圈内部空白不拦（可开文本框）；描边沿线选中；选中后内部可拖
    private static func testAnnotationTapRules(captured: NSImage) {
        let view = ShotView(frame: NSRect(origin: .zero, size: captured.size), captured: captured)
        var circle = Annotation(tool: .ellipse, color: .red, width: 4)
        circle.p1 = CGPoint(x: 100, y: 100)
        circle.p2 = CGPoint(x: 300, y: 300)
        view.annotations = [circle]
        view.selectedAnn = nil
        var ok = true
        // ① 圈心（空腔）：不命中 → 可开文本框
        if case .none = view.resolveAnnotationTap(at: CGPoint(x: 200, y: 200)) {} else { ok = false }
        // ② 描边沿线：选中
        if case .select(0) = view.resolveAnnotationTap(at: CGPoint(x: 300, y: 200)) {} else { ok = false }
        // ③ 选中后：圈心可拖（move）
        view.selectedAnn = 0
        if case .move(0) = view.resolveAnnotationTap(at: CGPoint(x: 200, y: 200)) {} else { ok = false }
        // ④ 选中后：手柄 → resize
        view.selectedAnn = 0
        if case .resize = view.resolveAnnotationTap(at: CGPoint(x: 300, y: 300)) {} else { ok = false }
        print("taprules: \(ok ? "PASS" : "FAIL")")
    }

    /// 导出区域正确性自检：选区四角标记必须落在导出图的四个角上
    ///（防「导出区域偏移」回归——这个 bug 藏了很多轮，因为内容+标注一起平移，肉眼很难发现）
    private static func testExportRegion(captured: NSImage, sel: CGRect, outDir: URL) {
        guard let img = Render.export(captured: captured, selection: sel, annotations: []),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { print("region: export FAIL"); return }
        let rep = NSBitmapImageRep(cgImage: cg)
        // 假底图选区左上角(view y-up)是深底+白聊天窗交界，右下角是深底；
        // 用已知内容断言：导出(0,0) 应= 选区左上角内容，(W-1,H-1) 应= 选区右下角内容
        let d = rep.bitmapData!
        func px(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let i = (y * cg.width + x) * 4
            return (Int(d[i]), Int(d[i+1]), Int(d[i+2]))
        }
        // 选区左上角 (220,610 y-up) 在假底图里是代码窗顶部深灰(0.16)附近；
        // 更稳的锚点：选区底边中点 (600,170 y-up) 在假底图里是白聊天窗底边附近(近白) vs 选区顶边中点 (600,610) 是深底(近黑)
        let topMid = px(cg.width / 2, 2)          // 选区顶边中点 → 深底(代码窗)
        let bottomMid = px(cg.width / 2, cg.height - 3)  // 选区底边中点 → 白聊天窗
        let topDark = topMid.0 < 120 && topMid.1 < 120 && topMid.2 < 140
        let bottomLight = bottomMid.0 > 200 && bottomMid.1 > 200 && bottomMid.2 > 200
        let ok = topDark && bottomLight
        print("region: 顶中=\(topMid) 底中=\(bottomMid) 上深下白=\(ok) -> \(ok ? "PASS" : "FAIL")")
    }

    /// 文字标注完整管道自检：startText → 输入 → commit → 导出，验证导出图里真有字
    ///（用户事故 2026-10-10：「编辑好的文字没出现在截图里」）
    private static func testTextPipeline(captured: NSImage, sel: CGRect, outDir: URL) {
        let view = ShotView(frame: NSRect(origin: .zero, size: captured.size), captured: captured)
        view.selection = sel
        view.tool = .text
        let anchor = CGPoint(x: sel.midX - 100, y: sel.midY)
        view.startText(at: anchor)
        view.textField?.stringValue = "管道测试文字"
        view.commitText()
        let committed = view.annotations.count == 1 && view.annotations[0].text == "管道测试文字"
        if let ann = view.annotations.first {
            print("textpipe: anchor=\(anchor) p1=\(ann.p1) bounds=\(ann.bounds)")
        }

        // 导出对比：有字 vs 无字，文字区域像素必须不同
        guard let withText = Render.export(captured: captured, selection: sel, annotations: view.annotations),
              let withoutText = Render.export(captured: captured, selection: sel, annotations: []),
              let cgA = withText.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let cgB = withoutText.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            print("textpipe: export FAIL"); return
        }
        // 整图找差异像素块（文字在哪不重要，在就行；整图均值会稀释、裁剪坐标换算易错，都绕过）
        let fa = ScrollCaptureSession.Frame(cgA)
        let fb = ScrollCaptureSession.Frame(cgB)
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1, diffs = 0
        fa.data.withUnsafeBytes { pa in
            fb.data.withUnsafeBytes { pb in
                let a = pa.bindMemory(to: UInt8.self), b = pb.bindMemory(to: UInt8.self)
                var y = 0
                while y < fa.h {
                    var x = 0
                    while x < fa.w {
                        let i = y * fa.bpr + x * 4
                        let d = abs(Int(a[i]) - Int(b[i])) + abs(Int(a[i+1]) - Int(b[i+1])) + abs(Int(a[i+2]) - Int(b[i+2]))
                        if d > 36 {
                            diffs += 1
                            minX = min(minX, x); maxX = max(maxX, x)
                            minY = min(minY, y); maxY = max(maxY, y)
                        }
                        x += 2
                        y += 0
                    }
                    y += 2
                }
            }
        }
        let visible = diffs > 50
        print("textpipe: 提交=\(committed) 差异像素=\(diffs) 区域=(\(minX),\(minY))-(\(maxX),\(maxY)) 可见=\(visible) -> \(committed && visible ? "PASS" : "FAIL")")
        Render.writePNG(withText, to: outDir.appendingPathComponent("textpipe.png"))
    }

    /// 标注移动/缩放自检：translated + resized（文字按比例、形状重设、箭头动端点）
    private static func testAnnotationTransforms() {
        var ok = true
        // 矩形移动
        var rc = Annotation(tool: .rect, color: .red, width: 3)
        rc.p1 = CGPoint(x: 10, y: 10); rc.p2 = CGPoint(x: 110, y: 60)
        let moved = rc.translated(by: CGPoint(x: 5, y: -5))
        ok = ok && moved.p1 == CGPoint(x: 15, y: 5) && moved.p2 == CGPoint(x: 115, y: 55)
        // 矩形拖右上角（handle 2）：锚左下(10,10)，拖到 (160, 80)
        let resized = rc.resized(handle: 2, from: rc.bounds, to: CGPoint(x: 160, y: 80))
        ok = ok && resized.bounds.width == 150 && resized.bounds.height == 70
        // 文字拖角缩放字号
        var tx = Annotation(tool: .text, color: .red, width: 3)
        tx.p1 = CGPoint(x: 0, y: 0); tx.text = "测试"
        let fsBefore = tx.fontSize
        let scaled = tx.resized(handle: 2, from: tx.bounds, to: CGPoint(x: tx.bounds.width * 2, y: 0))
        ok = ok && abs(scaled.fontSize - fsBefore * 2) < 0.5
        // 箭头拖 p2 侧手柄
        var ar = Annotation(tool: .arrow, color: .red, width: 3)
        ar.p1 = CGPoint(x: 0, y: 0); ar.p2 = CGPoint(x: 100, y: 100)
        let arMoved = ar.resized(handle: 2, from: ar.bounds, to: CGPoint(x: 200, y: 200))
        ok = ok && arMoved.p2 == CGPoint(x: 200, y: 200) && arMoved.p1 == CGPoint(x: 0, y: 0)
        print("transforms: \(ok ? "PASS" : "FAIL")")
    }

    /// 滚动会话全屏暗色层渲染自检（快照 + 挖洞 + 边框 + 提示条）
    private static func testDimLayer(captured: NSImage, sel: CGRect, outDir: URL) {
        let view = ScrollBorderView(frame: NSRect(origin: .zero, size: captured.size),
                                    region: sel, snapshot: captured)
        view.progress = 1260
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                let url = outDir.appendingPathComponent("dimlayer.png")
                try? data.write(to: url)
                print("dimlayer -> \(url.path)")
            }
        }
    }

    /// 真机冒烟（--selftest-live）：真定时器 + 真 SCK 抓帧 + 真会话。
    /// 专治「自检全绿但真机不跑」——定时器/权限/抓帧链路只有这条路能覆盖
    ///（事故 2026-10-09：scheduleTimer 初值守卫吃掉初始定时器，自检全绿但真机永不拼接）。
    private static func testLiveSession() {
        guard let screen = NSScreen.main else { print("live: no screen FAIL"); return }
        let region = CGRect(x: screen.frame.midX - 400, y: screen.frame.midY - 250, width: 800, height: 500)
        let session = ScrollCaptureSession(screen: screen, regionPts: region) { _ in }
        session.loggingEnabled = false
        session.start()
        // 主线程 runloop 转 1.6s（150ms 拍应抓 ~10 帧）
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            let n = session.debugDys.count
            session.cancel()
            print("live: 1.6s 内抓帧处理 \(n) 拍（期望 ≥4）-> \(n >= 4 ? "PASS" : "FAIL")")
        }
    }

    /// 失速重锚定自检：拼到 [0,1100) 后大幅回滚（超出帧间量程 340）→ 主匹配 nil → 重锚定找回 pos=200
    private static func testReanchor() {
        let W = 400, SRCH = 1600, FH = 400
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: SRCH,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { print("reanchor: init FAIL"); return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        NSGradient(colors: [NSColor(srgbRed: 0.2, green: 0.3, blue: 0.5, alpha: 1),
                            NSColor(srgbRed: 0.6, green: 0.3, blue: 0.2, alpha: 1)])!
            .draw(in: NSRect(x: 0, y: 0, width: W, height: SRCH), angle: -90)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 20, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        for y in stride(from: 10, to: SRCH - 30, by: 40) {
            NSString(string: "row \(y)").draw(at: CGPoint(x: 20, y: CGFloat(y)), withAttributes: attrs)
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let src = rep.cgImage else { return }
        func frame(_ off: Int) -> ScrollCaptureSession.Frame {
            ScrollCaptureSession.Frame(src.cropping(to: CGRect(x: 0, y: off, width: W, height: FH))!)
        }
        let session = ScrollCaptureSession(screen: NSScreen.main ?? NSScreen.screens[0],
                                           regionPts: CGRect(x: 0, y: 0, width: W, height: FH)) { _ in }
        session.loggingEnabled = false
        session.reanchorMinInterval = 0
        for off in [0, 87, 171, 258, 345, 432, 519, 606, 700] { session.process(newFrame: frame(off)) }
        // 大幅回滚到 200（相对上一帧 700 后退 500，超出量程 340）→ 主匹配必 nil → 重锚定应找回
        session.process(newFrame: frame(200))
        let ok = session.debugLastPos == 200
        print("reanchor: 大幅回滚后 lastPos=\(session.debugLastPos)（期望 200）-> \(ok ? "PASS" : "FAIL")")
    }

    /// 白底稀疏文本页：上滚（手滑）必须 nil（幻影 dy 会重复拼接）；正常下滚仍正确匹配
    private static func testWhitePageMatching(outDir: URL) {
        let W = 400, SRCH = 1600, FH = 400
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: SRCH,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { print("whitematch: init FAIL"); return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: W, height: SRCH).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 16, weight: .regular),
            .foregroundColor: NSColor.black,
        ]
        // 各行内容长度/文本差异要大——否则周期性行 + 一个数字差异会把帧变成完美周期纹理（幻影温床）
        let lineTexts = ["发起人的需求已经整理完毕", "ok", "这是一个中等长度的回复，包含一些细节描述",
                         "短", "本次迭代的目标是完成所有功能的联调与验收测试工作", "收到了，我马上看一下这个问题"]
        for (i, y) in [100, 360, 620, 880, 1140, 1400].enumerated() {
            NSString(string: lineTexts[i]).draw(at: CGPoint(x: 16, y: CGFloat(y)), withAttributes: attrs)
        }
        NSGraphicsContext.restoreGraphicsState()
        let dbg = NSImage(size: NSSize(width: W, height: SRCH))
        dbg.addRepresentation(rep)
        Render.writePNG(dbg, to: outDir.appendingPathComponent("white-src.png"))
        guard let src = rep.cgImage else { print("whitematch: src FAIL"); return }
        func frame(_ off: Int) -> ScrollCaptureSession.Frame {
            ScrollCaptureSession.Frame(src.cropping(to: CGRect(x: 0, y: off, width: W, height: FH))!)
        }
        // 上滚（内容下移）：应识别为反向 -87（真匹配，不是幻影）；幻影的防法在「全白对齐被纹理闸门过滤」
        let up = ScrollCaptureSession.scrollDeltaDetailed(prev: frame(258), new: frame(171))
        let p1 = up.dy == -87
        print("whitematch: 上滚 dy=\(up.dy.map(String.init) ?? "nil") tex=\(up.tex) -> \(p1 ? "PASS" : "FAIL")")
        // 正常下滚：稀疏文本提供足够纹理，仍应正确匹配
        let down = ScrollCaptureSession.scrollDeltaDetailed(prev: frame(0), new: frame(87))
        let p2 = down.dy == 87
        print("whitematch: 下滚 dy=\(down.dy.map(String.init) ?? "nil") tex=\(down.tex) -> \(p2 ? "PASS" : "FAIL")")
        // 幻影回归（真实事故 2026-10-09：dy=660 顶满边界、err 5.95 擦边过线 → 660 行错位追加）：
        // 大跳变两帧零重叠，精确匹配必须 nil（旧模糊匹配会瞎猜）
        let phantom = ScrollCaptureSession.scrollDeltaDetailed(prev: frame(0), new: frame(1100))
        let p3 = phantom.dy == nil
        print("whitematch: 大跳变零重叠 dy=\(phantom.dy.map(String.init) ?? "nil") err=\(String(format:"%.2f",phantom.fineErr)) tex=\(phantom.tex) -> \(p3 ? "PASS" : "FAIL")")
        // 噪声回归（SCK 分数像素 sourceRect 重采样/光标闪烁）：帧内撒 ±8 噪声点，仍应匹配 dy=87
        guard let noisyRep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: FH,
                                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                              isPlanar: false, colorSpaceName: .deviceRGB,
                                              bytesPerRow: 0, bitsPerPixel: 0),
              let nctx = NSGraphicsContext(bitmapImageRep: noisyRep) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nctx
        NSImage(cgImage: frame(87).cg, size: NSSize(width: W, height: FH)).draw(in: NSRect(x: 0, y: 0, width: W, height: FH))
        NSColor.gray.setFill()
        var rng: UInt64 = 42
        for _ in 0..<200 {   // 撒 200 个 1px 噪声点（＜0.5% 行像素预算内）
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            let nx = Int(rng >> 33) % W, ny = Int(rng >> 11) % FH
            NSRect(x: nx, y: ny, width: 1, height: 1).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let noisy = ScrollCaptureSession.Frame(noisyRep.cgImage!)
        let noisyMatch = ScrollCaptureSession.scrollDeltaDetailed(prev: frame(0), new: noisy)
        let p4 = noisyMatch.dy == 87
        print("whitematch: 噪声帧 dy=\(noisyMatch.dy.map(String.init) ?? "nil") err=\(String(format:"%.2f",noisyMatch.fineErr)) tex=\(noisyMatch.tex) -> \(p4 ? "PASS" : "FAIL")")
    }

    /// 造 1600px 长图，用滑动窗口模拟滚动帧，验证匹配 + 拼接还原
    private static func testScrollStitch(outDir: URL) {
        let W = 400, SRCH = 1600, FH = 400
        // 源图：渐变底 + 每 40px 一行序号
        guard let srcRep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: SRCH,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                            isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0),
              let sctx = NSGraphicsContext(bitmapImageRep: srcRep) else { print("stitch: init FAIL"); return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = sctx
        NSGradient(colors: [NSColor(srgbRed: 0.2, green: 0.3, blue: 0.5, alpha: 1),
                            NSColor(srgbRed: 0.6, green: 0.3, blue: 0.2, alpha: 1)])!
            .draw(in: NSRect(x: 0, y: 0, width: W, height: SRCH), angle: -90)
        let numAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 20, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        for y in stride(from: 10, to: SRCH - 30, by: 40) {
            NSString(string: "row \(y)").draw(at: CGPoint(x: 20, y: CGFloat(y)), withAttributes: numAttrs)
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let srcCG = srcRep.cgImage else { print("stitch: src FAIL"); return }

        // 模拟双向滚动：下滚 → 上滚回原位（已覆盖，不动）→ 继续上滚越过首帧（前插）
        // 帧 i = 源图 [off_i, off_i+FH)（CGImage.cropping 原点左上）
        let offsets = [171, 258, 171, 87, 0]
        let frames: [ScrollCaptureSession.Frame] = offsets.compactMap { off in
            srcCG.cropping(to: CGRect(x: 0, y: off, width: W, height: FH)).map { ScrollCaptureSession.Frame($0) }
        }
        guard frames.count == offsets.count else { print("stitch: frames FAIL"); return }

        // 用真实会话驱动（双向水位线逻辑）
        var result: NSImage?
        let session = ScrollCaptureSession(screen: NSScreen.main ?? NSScreen.screens[0],
                                           regionPts: CGRect(x: 0, y: 0, width: W, height: FH)) { img in
            result = img
        }
        for f in frames { session.process(newFrame: f) }
        print("stitch: matchedDys=\(session.debugDys.map { $0.map(String.init) ?? "nil" })")
        session.finish()
        guard let composed = result,
              let composedCG = composed.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            print("stitch: compose FAIL"); return
        }
        // 期望：覆盖源图 [0, 258+FH) 共 658 行（上滚越过首帧的内容被前插进来）
        let expectH = FH + 258
        guard let refCG = srcCG.cropping(to: CGRect(x: 0, y: 0, width: W, height: expectH)) else {
            print("stitch: ref FAIL"); return
        }
        let err = ScrollCaptureSession.stripError(prev: ScrollCaptureSession.Frame(composedCG),
                                                  new: ScrollCaptureSession.Frame(refCG), dy: 0)
        let pass = composedCG.height == expectH && err < 3.0
        print("stitch: 双向滚动 offsets=\(offsets) 期望高度=\(expectH) 实际=\(composedCG.height) 误差=\(String(format: "%.2f", err)) -> \(pass ? "PASS" : "FAIL")")
        let out = NSImage(size: NSSize(width: W, height: composedCG.height))
        out.addRepresentation(NSBitmapImageRep(cgImage: composedCG))
        Render.writePNG(out, to: outDir.appendingPathComponent("scroll-stitch.png"))
    }

    /// 假底图：两个窗口 + 一段「机密」文字
    private static func fakeScreenshot() -> NSImage {
        let size = NSSize(width: 1200, height: 800)
        let img = NSImage(size: size)
        img.lockFocus()
        defer { img.unlockFocus() }

        NSColor(srgbRed: 0.11, green: 0.13, blue: 0.18, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()

        // 窗口 A（代码编辑器）
        NSColor(white: 0.16, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 180, y: 430, width: 840, height: 280), xRadius: 12, yRadius: 12).fill()
        NSColor(white: 0.22, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 180, y: 680, width: 840, height: 30), xRadius: 12, yRadius: 12).fill()
        let codeAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 15, weight: .regular),
            .foregroundColor: NSColor(srgbRed: 0.55, green: 0.85, blue: 0.55, alpha: 1),
        ]
        let lines = ["import AppKit", "", "final class ShotView: NSView {", "    // 画圈、打码、箭头……", "}"]
        for (i, l) in lines.enumerated() {
            NSString(string: l).draw(at: CGPoint(x: 210, y: 640 - CGFloat(i) * 26), withAttributes: codeAttrs)
        }

        // 窗口 B（聊天窗）
        NSColor(white: 0.94, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 300, y: 120, width: 620, height: 260), xRadius: 12, yRadius: 12).fill()
        let chatAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor(white: 0.2, alpha: 1),
        ]
        NSString(string: "把这张截图圈出来发群里").draw(at: CGPoint(x: 330, y: 330), withAttributes: chatAttrs)

        // 「机密」区（打码目标）
        let secretAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 16, weight: .bold),
            .foregroundColor: NSColor(srgbRed: 0.9, green: 0.3, blue: 0.3, alpha: 1),
        ]
        NSString(string: "SECRET_TOKEN=sk-live-a1b2c3d4").draw(at: CGPoint(x: 340, y: 200), withAttributes: secretAttrs)

        return img
    }

    private static func demoAnnotations() -> [Annotation] {
        var out: [Annotation] = []

        // 红圈（椭圆）
        var ell = Annotation(tool: .ellipse, color: Model.palette[0], width: 4)
        ell.p1 = CGPoint(x: 300, y: 440)
        ell.p2 = CGPoint(x: 620, y: 690)
        out.append(ell)

        // 蓝箭头指向红圈
        var arr = Annotation(tool: .arrow, color: Model.palette[4], width: 4)
        arr.p1 = CGPoint(x: 860, y: 230)
        arr.p2 = CGPoint(x: 620, y: 470)
        out.append(arr)

        // 绿矩形框住聊天窗标题区
        var rc = Annotation(tool: .rect, color: Model.palette[3], width: 3)
        rc.p1 = CGPoint(x: 300, y: 330)
        rc.p2 = CGPoint(x: 920, y: 380)
        out.append(rc)

        // 黄画笔波浪
        var pen = Annotation(tool: .pen, color: Model.palette[2], width: 4)
        pen.points = (0...40).map { i in
            CGPoint(x: 260 + CGFloat(i) * 12, y: 250 + 18 * sin(CGFloat(i) / 4))
        }
        out.append(pen)

        // 马赛克盖住机密
        var mo = Annotation(tool: .mosaic, color: .gray, width: 1)
        mo.p1 = CGPoint(x: 330, y: 185)
        mo.p2 = CGPoint(x: 700, y: 218)
        out.append(mo)

        // 文字
        var tx = Annotation(tool: .text, color: Model.palette[0], width: 3)
        tx.p1 = CGPoint(x: 720, y: 190)
        tx.text = "已打码 ✓"
        out.append(tx)

        return out
    }
}
