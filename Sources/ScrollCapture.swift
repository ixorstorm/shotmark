import AppKit
import CoreGraphics
import Carbon.HIToolbox

/// 滚动截屏会话：固定选区定时抓帧 → 帧间模板匹配求滚动位移 → 逐帧拼接长图。
/// 交互：边框提示窗悬在选区上（不拦鼠标），空格/回车完成，Esc 取消。
final class ScrollCaptureSession: NSObject {

    /// 一帧的 RGBA8888 位图数据（用于匹配）
    struct Frame {
        let cg: CGImage
        let data: Data
        let w: Int
        let h: Int
        let bpr: Int

        init(_ cg: CGImage) {
            let w = cg.width
            let h = cg.height
            let bpr = w * 4
            var d = Data(count: h * bpr)
            d.withUnsafeMutableBytes { ptr in
                guard let base = ptr.baseAddress,
                      let ctx = CGContext(data: base, width: w, height: h,
                                          bitsPerComponent: 8, bytesPerRow: bpr,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            self.cg = cg
            self.w = w
            self.h = h
            self.bpr = bpr
            self.data = d
        }
    }

    private let screen: NSScreen
    private let regionPts: CGRect          // 屏内点坐标（AppKit y-up）
    private let onFinish: (NSImage?) -> Void

    private var borderWin: NSWindow?
    private var timer: Timer?
    private var capturing = false
    private var hotKeyRefs: [EventHotKeyRef?] = []

    private var firstFrame: Frame?
    private var lastFrame: Frame?
    private var strips: [CGImage] = []
    private var pointScale: CGFloat = 2

    init(screen: NSScreen, regionPts: CGRect, onFinish: @escaping (NSImage?) -> Void) {
        self.screen = screen
        self.regionPts = regionPts
        self.onFinish = onFinish
    }

    // MARK: - 生命周期

    func start() {
        showBorder()
        hotKeyRefs = HotKey.registerRaw(keys: [49, 36, 53]) { [weak self] code in
            guard let self = self else { return }
            if code == 53 { self.cancel() } else { self.finish() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.tick()
        }
        tick()
    }

    func finish() {
        let img = compose()
        teardown()
        onFinish(img)
    }

    func cancel() {
        teardown()
        onFinish(nil)
    }

    private func teardown() {
        timer?.invalidate()
        timer = nil
        HotKey.unregisterRaw(hotKeyRefs)
        hotKeyRefs = []
        borderWin?.close()
        borderWin = nil
    }

    // MARK: - 抓帧

    private func tick() {
        guard !capturing else { return }
        capturing = true
        let screen = self.screen
        let region = self.regionPts
        Task { @MainActor in
            defer { capturing = false }
            do {
                let cg = try await Capture.grabRegion(screen: screen, regionPts: region)
                process(newFrame: Frame(cg))
            } catch {
                // 单帧失败忽略，下一拍重试
            }
        }
    }

    private func process(newFrame nf: Frame) {
        guard firstFrame != nil else {
            firstFrame = nf
            lastFrame = nf
            pointScale = CGFloat(nf.w) / regionPts.width
            return
        }
        guard let prev = lastFrame else { return }
        guard let dy = Self.scrollDelta(prev: prev, new: nf) else { return }  // 未匹配：保持 prev，下拍重试
        if dy > 0 {
            if let strip = nf.cg.cropping(to: CGRect(x: 0, y: nf.h - dy, width: nf.w, height: dy)) {
                strips.append(strip)
            }
        }
        lastFrame = nf
    }

    // MARK: - 拼接

    private func compose() -> NSImage? {
        guard let first = firstFrame else { return nil }
        return Self.compose(first: first.cg, strips: strips, pointScale: pointScale)
    }

    static func compose(first: CGImage, strips: [CGImage], pointScale: CGFloat) -> NSImage? {
        let w = first.width
        let totalH = first.height + strips.reduce(0) { $0 + $1.height }
        guard totalH > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: w, pixelsHigh: totalH,
                                         bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .high
        // AppKit y-up：首帧贴顶（y = totalH - first.height），后续条带依次向下堆
        let wf = CGFloat(first.width)
        var y = CGFloat(totalH) - CGFloat(first.height)
        NSImage(cgImage: first, size: NSSize(width: wf, height: CGFloat(first.height)))
            .draw(in: NSRect(x: 0, y: y, width: wf, height: CGFloat(first.height)))
        for s in strips {
            y -= CGFloat(s.height)
            NSImage(cgImage: s, size: NSSize(width: wf, height: CGFloat(s.height)))
                .draw(in: NSRect(x: 0, y: y, width: wf, height: CGFloat(s.height)))
        }
        NSGraphicsContext.restoreGraphicsState()
        let img = NSImage(size: NSSize(width: wf / pointScale, height: CGFloat(totalH) / pointScale))
        img.addRepresentation(rep)
        return img
    }

    // MARK: - 帧间匹配（static，便于离线自检）

    /// 求 new 相对 prev 的向上滚动位移（像素行数，0 = 未动，nil = 无法匹配）
    static func scrollDelta(prev: Frame, new: Frame) -> Int? {
        let H = prev.h
        guard new.h == H, new.w == prev.w else { return nil }
        let maxDelta = H - 60
        guard maxDelta > 0 else { return 0 }
        // 粗扫（步长 8）
        var best = 0, bestErr = Double.greatestFiniteMagnitude
        var dy = 0
        while dy <= maxDelta {
            let e = stripError(prev: prev, new: new, dy: dy)
            if e < bestErr { bestErr = e; best = dy }
            dy += 8
        }
        // 精扫（±8 步长 1）
        var fine = best, fineErr = bestErr
        let lo = max(0, best - 8), hi = min(maxDelta, best + 8)
        if lo <= hi {
            for d in lo...hi {
                let e = stripError(prev: prev, new: new, dy: d)
                if e < fineErr { fineErr = e; fine = d }
            }
        }
        if fineErr < 6.0 { return fine }            // 高置信（含 dy=0 静止）
        if fineErr < 10.0, fine > 0 { return fine } // 有噪声但仍有明确最小值
        return nil
    }

    /// prev 的 [dy..H) 与 new 的 [0..H-dy) 的平均像素差（抽样）
    static func stripError(prev: Frame, new: Frame, dy: Int) -> Double {
        let overlap = prev.h - dy
        guard overlap > 40 else { return .greatestFiniteMagnitude }
        let rowStep = max(2, overlap / 64)
        let colStep = max(4, prev.w / 96)
        var sum = 0.0, n = 0.0
        prev.data.withUnsafeBytes { pBuf in
            new.data.withUnsafeBytes { nBuf in
                let p = pBuf.bindMemory(to: UInt8.self)
                let q = nBuf.bindMemory(to: UInt8.self)
                var r = 0
                while r < overlap {
                    let pr = (dy + r) * prev.bpr
                    let nr = r * new.bpr
                    var c = 0
                    while c < prev.w {
                        let i = pr + c * 4, j = nr + c * 4
                        sum += Double(abs(Int(p[i]) - Int(q[j]))
                                      + abs(Int(p[i + 1]) - Int(q[j + 1]))
                                      + abs(Int(p[i + 2]) - Int(q[j + 2])))
                        n += 3
                        c += colStep
                    }
                    r += rowStep
                }
            }
        }
        return n > 0 ? sum / n : .greatestFiniteMagnitude
    }

    // MARK: - 边框提示窗

    private func showBorder() {
        let padX: CGFloat = 6, padTop: CGFloat = 34
        let frame = CGRect(x: screen.frame.minX + regionPts.minX - padX,
                           y: screen.frame.minY + regionPts.minY - padX,
                           width: regionPts.width + padX * 2,
                           height: regionPts.height + padX * 2 + padTop)
        let win = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        win.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.isOpaque = false
        win.backgroundColor = .clear
        win.ignoresMouseEvents = true
        win.contentView = ScrollBorderView(frame: NSRect(origin: .zero, size: frame.size))
        win.orderFrontRegardless()
        borderWin = win
    }
}

/// 选区边框（虚线蓝）+ 顶部操作提示
final class ScrollBorderView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        // 顶部提示条
        let hint = "滚动截屏进行中 · 滚动滚轮 · 空格/回车 完成 · Esc 取消"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let ts = NSString(string: hint).size(withAttributes: attrs)
        let bar = NSRect(x: bounds.midX - ts.width / 2 - 10, y: bounds.maxY - 30,
                         width: ts.width + 20, height: 24)
        NSColor(white: 0.1, alpha: 0.9).setFill()
        NSBezierPath(roundedRect: bar, xRadius: 7, yRadius: 7).fill()
        NSString(string: hint).draw(at: CGPoint(x: bar.minX + 10, y: bar.minY + 5), withAttributes: attrs)
        // 虚线边框
        let r = NSRect(x: 7, y: 7, width: bounds.width - 14, height: bounds.height - 14 - 34)
        let path = NSBezierPath(rect: r)
        let dash: [CGFloat] = [8, 6]
        path.setLineDash(dash, count: 2, phase: 0)
        NSColor(srgbRed: 0.13, green: 0.59, blue: 0.95, alpha: 1).setStroke()
        path.lineWidth = 2
        path.stroke()
    }
}
