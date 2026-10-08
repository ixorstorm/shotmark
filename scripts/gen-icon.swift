import AppKit

/// ShotMark 图标生成器：Swift 矢量直绘，逐尺寸渲染（保证 16px 小图也清晰）
/// 用法：gen-icon <输出.iconset 目录>
/// 设计：深蓝渐变圆角底 + 白色取景框四角（截图）+ 手绘红圈（标注）

func drawIcon(canvas s: CGFloat) {
    let ctx = NSGraphicsContext.current!

    // ── 底：圆角矩形 + 深蓝渐变 ──
    let inset = s * 0.045
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let base = NSBezierPath(roundedRect: rect, xRadius: s * 0.225, yRadius: s * 0.225)
    let grad = NSGradient(colors: [
        NSColor(srgbRed: 0.18, green: 0.24, blue: 0.38, alpha: 1),   // 顶：亮一点的蓝黑
        NSColor(srgbRed: 0.07, green: 0.09, blue: 0.17, alpha: 1),   // 底：深蓝黑
    ])!
    grad.draw(in: base, angle: -90)
    NSColor.white.withAlphaComponent(0.10).setStroke()
    base.lineWidth = max(1, s * 0.004)
    base.stroke()

    // ── 取景框四角（白）──
    let cw = s * 0.028     // 线宽
    let cl = s * 0.145     // 角臂长
    let ci = s * 0.135     // 距底边内距
    NSColor.white.withAlphaComponent(0.92).setStroke()
    let corners = NSBezierPath()
    corners.lineWidth = cw
    corners.lineCapStyle = .round
    let l = rect.minX + ci, r = rect.maxX - ci, b = rect.minY + ci, t = rect.maxY - ci
    // 左上 ⌜
    corners.move(to: CGPoint(x: l, y: t - cl)); corners.line(to: CGPoint(x: l, y: t)); corners.line(to: CGPoint(x: l + cl, y: t))
    // 右上 ⌝
    corners.move(to: CGPoint(x: r - cl, y: t)); corners.line(to: CGPoint(x: r, y: t)); corners.line(to: CGPoint(x: r, y: t - cl))
    // 右下 ⌟
    corners.move(to: CGPoint(x: r, y: b + cl)); corners.line(to: CGPoint(x: r, y: b)); corners.line(to: CGPoint(x: r - cl, y: b))
    // 左下 ⌞
    corners.move(to: CGPoint(x: l + cl, y: b)); corners.line(to: CGPoint(x: l, y: b)); corners.line(to: CGPoint(x: l, y: b + cl))
    corners.stroke()

    // ── 红圈（手绘椭圆，微倾 -7°）──
    ctx.saveGraphicsState()
    let tr = NSAffineTransform()
    tr.translateX(by: s / 2, yBy: s / 2)
    tr.rotate(byDegrees: -7)
    tr.translateX(by: -s / 2, yBy: -s / 2)
    tr.concat()
    NSColor(srgbRed: 1.0, green: 0.27, blue: 0.23, alpha: 1).setStroke()
    let ew = s * 0.50, eh = s * 0.355
    let ell = NSBezierPath(ovalIn: NSRect(x: (s - ew) / 2, y: (s - eh) / 2 + s * 0.01, width: ew, height: eh))
    ell.lineWidth = s * 0.043
    ell.lineCapStyle = .round
    ell.stroke()
    ctx.restoreGraphicsState()
}

func renderPixels(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    ctx.imageInterpolation = .high
    drawIcon(canvas: CGFloat(px))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/ShotMark.iconset"
try! FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let sizes = [16, 32, 64, 128, 256, 512, 1024]
for sz in sizes {
    let rep = renderPixels(sz)
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: "\(outDir)/icon_\(sz)x\(sz).png"))
    if sz <= 512 {
        let rep2 = renderPixels(sz * 2)
        let data2 = rep2.representation(using: .png, properties: [:])!
        try! data2.write(to: URL(fileURLWithPath: "\(outDir)/icon_\(sz)x\(sz)@2x.png"))
    }
}
print("iconset -> \(outDir)（13 张）")
