import AppKit

/// 自检模式：`ShotMark --selftest`
/// 不碰真实屏幕（无需屏幕录制权限），生成假底图 + 各类型标注，
/// 输出两张 PNG：导出国（裁剪+标注）与完整界面图（蒙层/工具栏/手柄）。
enum SelfTest {

    static var enabled: Bool { CommandLine.arguments.contains("--selftest") }

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
        for (i, y) in [100, 400, 700, 1000, 1300].enumerated() {
            NSString(string: "这是第 \(i) 行聊天文本 content line").draw(at: CGPoint(x: 16, y: CGFloat(y)), withAttributes: attrs)
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
        print("whitematch: 大跳变零重叠 dy=\(phantom.dy.map(String.init) ?? "nil") -> \(p3 ? "PASS" : "FAIL")")
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
