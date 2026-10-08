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
