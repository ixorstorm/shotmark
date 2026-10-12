import AppKit

/// 渲染：标注绘制（视图显示与导出共用）+ 导出成图 + PNG 编码 + SF Symbol 着色
enum Render {

    // MARK: - 标注绘制（在当前 NSGraphicsContext 中，坐标 = 视图点坐标）

    static func draw(annotation a: Annotation, mosaicSource: NSImage?) {
        a.color.setStroke()
        a.color.setFill()
        switch a.tool {
        case .pen:
            guard a.points.count > 1 else { return }
            let path = NSBezierPath()
            path.lineWidth = a.width
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: a.points[0])
            for p in a.points.dropFirst() { path.line(to: p) }
            path.stroke()

        case .arrow:
            drawArrow(from: a.p1, to: a.p2, lw: a.width)

        case .rect:
            let path = NSBezierPath(rect: CGRect(p1: a.p1, p2: a.p2))
            path.lineWidth = a.width
            path.stroke()

        case .ellipse:
            let path = NSBezierPath(ovalIn: CGRect(p1: a.p1, p2: a.p2))
            path.lineWidth = a.width
            path.stroke()

        case .text:
            guard !a.text.isEmpty else { return }
            let fontSize = a.fontSize   // 含拖角缩放（scale）
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
                .foregroundColor: a.color,
            ]
            NSString(string: a.text).draw(at: a.p1, withAttributes: attrs)

        case .mosaic:
            drawMosaic(rect: CGRect(p1: a.p1, p2: a.p2), source: mosaicSource)
        }
    }

    private static func drawArrow(from a: CGPoint, to b: CGPoint, lw: CGFloat) {
        let path = NSBezierPath()
        path.lineWidth = lw
        path.lineCapStyle = .round
        path.move(to: a)
        path.line(to: b)
        path.stroke()
        let ang = atan2(b.y - a.y, b.x - a.x)
        let hl = max(9, lw * 3.2)
        for delta in [CGFloat.pi * 0.82, -CGFloat.pi * 0.82] {
            let hp = CGPoint(x: b.x + hl * cos(ang + delta), y: b.y + hl * sin(ang + delta))
            let head = NSBezierPath()
            head.lineWidth = lw
            head.lineCapStyle = .round
            head.move(to: b)
            head.line(to: hp)
            head.stroke()
        }
    }

    /// 马赛克：把底图对应区域缩到 ~1/9 再放大（最近邻），块大小 ≈ 9pt
    private static func drawMosaic(rect r: CGRect, source: NSImage?) {
        guard let source = source, r.width > 2, r.height > 2 else {
            NSColor.gray.withAlphaComponent(0.6).setFill()
            r.fill()
            return
        }
        let bw = max(1, Int(r.width / 9)), bh = max(1, Int(r.height / 9))
        guard let small = NSBitmapImageRep(bitmapDataPlanes: nil,
                                           pixelsWide: bw, pixelsHigh: bh,
                                           bitsPerSample: 8, samplesPerPixel: 4,
                                           hasAlpha: true, isPlanar: false,
                                           colorSpaceName: .deviceRGB,
                                           bytesPerRow: 0, bitsPerPixel: 0),
              let sctx = NSGraphicsContext(bitmapImageRep: small) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = sctx
        sctx.imageInterpolation = .high
        source.draw(in: NSRect(x: 0, y: 0, width: bw, height: bh),
                    from: r, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        let img = NSImage(size: NSSize(width: bw, height: bh))
        img.addRepresentation(small)
        NSGraphicsContext.current?.imageInterpolation = .none
        img.draw(in: r)
        NSGraphicsContext.current?.imageInterpolation = .high
    }

    // MARK: - 导出（按选区裁剪 + 所有标注，输出 Retina 像素图）

    static func export(captured: NSImage, selection sel: CGRect, annotations: [Annotation]) -> NSImage? {
        guard let rep0 = captured.representations.first, rep0.pixelsWide > 0 else { return nil }
        let scale = CGFloat(rep0.pixelsWide) / captured.size.width
        let pxW = Int((sel.width * scale).rounded())
        let pxH = Int((sel.height * scale).rounded())
        guard pxW > 0, pxH > 0,
              let cgFull = captured.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        // 底图：CGImage 直接按像素裁剪。⚠️ 不用 NSAffineTransform——实测它在翻转位图上下文中
        // 组合行为不可控（网格扫描实锤：多数选区导出透明/错位，2026-10-12 白图事故根因）
        let cropPx = CGRect(x: (sel.minX * scale).rounded(),
                            y: ((captured.size.height - sel.maxY) * scale).rounded(),  // 视图 y-up → 像素左上原点
                            width: sel.width * scale, height: sel.height * scale)
        guard let cgCrop = cgFull.cropping(to: cropPx) else { return nil }
        let baseImg = NSImage(cgImage: cgCrop, size: NSSize(width: pxW, height: pxH))

        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: pxW, pixelsHigh: pxH,
                                         bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .high
        baseImg.draw(in: NSRect(x: 0, y: 0, width: pxW, height: pxH))
        // 标注平移+缩放到像素坐标后 1:1 绘制（同样不经上下文变换）
        for a in annotations {
            draw(annotation: a.pixelMapped(scale: scale, dx: -sel.minX, dy: -sel.minY), mosaicSource: baseImg)
        }
        NSGraphicsContext.restoreGraphicsState()

        let img = NSImage(size: NSSize(width: sel.width, height: sel.height))
        img.addRepresentation(rep)
        return img
    }

    static func pngData(of img: NSImage) -> Data? {
        guard let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    @discardableResult
    static func writePNG(_ img: NSImage, to url: URL) -> Bool {
        guard let d = pngData(of: img) else { return false }
        do { try d.write(to: url); return true } catch { return false }
    }

    // MARK: - SF Symbol 着色图标

    static func symbolImage(_ name: String, size: CGFloat, tint: NSColor) -> NSImage {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
            return NSImage()
        }
        let conf = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
        let configured = base.withSymbolConfiguration(conf) ?? base
        let sz = configured.size
        return NSImage(size: sz, flipped: false) { rect in
            configured.draw(in: rect)
            tint.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }
}
