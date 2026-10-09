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
    private weak var borderView: ScrollBorderView?
    private var previewWin: NSWindow?
    private weak var previewImgView: NSImageView?
    private var lastPreviewAt = Date.distantPast
    private var timer: Timer?
    private var capturing = false
    private var hotKeyRefs: [EventHotKeyRef?] = []

    private var firstFrame: Frame?
    private var lastFrame: Frame?
    /// 已捕获片段（pos = 片段顶部绝对行位置，相对第一帧顶部；支持负值 = 上滚前插）
    private var segments: [(pos: Int, cg: CGImage)] = []
    private var pointScale: CGFloat = 2
    /// 水位线：已拼接内容的底部/顶部（像素行，相对第一帧顶部）与上一帧的绝对顶部位置。
    /// 支持来回滚动（手滑上滚/上下反复）——新帧只有超出水位线的部分才会被拼接，杜绝重复。
    private var capturedBottom = 0
    private var capturedTop = 0
    private var lastPos = 0
    /// 每次 process 的匹配 dy（含 nil），自检调试用
    var debugDys: [Int?] = []
    /// 已销毁：阻断 finish/cancel 重入与 in-flight 抓帧复活窗口
    private var tornDown = false

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
        guard !tornDown else { return }
        tornDown = true
        let img = compose()
        teardown()
        onFinish(img)
    }

    func cancel() {
        guard !tornDown else { return }
        tornDown = true
        teardown()
        onFinish(nil)
    }

    private func teardown() {
        timer?.invalidate()
        timer = nil
        // 注销热键延到下一个 runloop tick：当前可能正处在这枚热键的 Carbon 事件分发中，
        // 同步注销会释放事件管理器仍在使用的结构 → 堆腐坏（实测三次 pool-pop SIGSEGV）
        let refs = hotKeyRefs
        hotKeyRefs = []
        DispatchQueue.main.async { HotKey.unregisterRaw(refs) }
        borderWin?.close()
        borderWin = nil
        previewWin?.close()
        previewWin = nil
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

    /// 帧处理（internal 便于离线自检直接驱动）
    func process(newFrame nf: Frame) {
        guard !tornDown else { return }
        guard firstFrame != nil else {
            firstFrame = nf
            lastFrame = nf
            pointScale = CGFloat(nf.w) / regionPts.width
            segments = [(0, nf.cg)]
            capturedBottom = nf.h
            capturedTop = 0
            lastPos = 0
            updatePreview(force: true)      // 第一帧即出预览
            return
        }
        guard let prev = lastFrame else { return }
        let detail = Self.scrollDeltaDetailed(prev: prev, new: nf)
        debugDys.append(detail.dy)
        guard let dy = detail.dy else {
            debugLog(detail: detail, appended: 0)
            return   // 未匹配（滚动过快/低纹理）：保持 prev，下拍重试
        }
        let p = lastPos + dy                       // 本帧顶部的绝对位置（dy>0 内容上移 / dy<0 用户上滚）
        var appended = 0
        if dy >= 0 {
            // 底部追加超出水位线的部分
            let start = capturedBottom - p
            if start < nf.h {
                let s = max(0, start)
                if s < nf.h,
                   let strip = nf.cg.cropping(to: CGRect(x: 0, y: s, width: nf.w, height: nf.h - s)) {
                    segments.append((p + s, strip))
                    capturedBottom = max(capturedBottom, p + nf.h)
                    appended = nf.h - s
                }
            }
        } else {
            // 用户上滚：顶部前插水位线之上的新内容
            let headRows = capturedTop - p
            if headRows > 0 {
                let take = min(headRows, nf.h)
                if let strip = nf.cg.cropping(to: CGRect(x: 0, y: 0, width: nf.w, height: take)) {
                    segments.append((p, strip))
                    capturedTop = min(capturedTop, p)
                    appended = take
                }
            }
        }
        if appended > 0 {
            borderView?.progress = capturedBottom - capturedTop
            updatePreview()
        }
        debugLog(detail: detail, appended: appended)
        lastPos = p
        lastFrame = nf
    }

    // MARK: - 拼接

    private func compose() -> NSImage? {
        guard !segments.isEmpty else { return nil }
        return Self.compose(segments: segments, top: capturedTop, bottom: capturedBottom, pointScale: pointScale)
    }

    /// segments（pos = 片段顶部绝对位置）按位置堆叠成完整长图
    static func compose(segments: [(pos: Int, cg: CGImage)], top: Int, bottom: Int, pointScale: CGFloat) -> NSImage? {
        guard let first = segments.first else { return nil }
        let w = first.cg.width
        let totalH = bottom - top
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
        let wf = CGFloat(w)
        for seg in segments {
            let h = seg.cg.height
            // AppKit y-up：pos 越小越靠上 → y = totalH - (pos - top) - h
            let y = totalH - (seg.pos - top) - h
            NSImage(cgImage: seg.cg, size: NSSize(width: wf, height: CGFloat(h)))
                .draw(in: NSRect(x: 0, y: CGFloat(y), width: wf, height: CGFloat(h)))
        }
        NSGraphicsContext.restoreGraphicsState()
        let img = NSImage(size: NSSize(width: wf / pointScale, height: CGFloat(totalH) / pointScale))
        img.addRepresentation(rep)
        return img
    }


    // MARK: - 帧间匹配（static，便于离线自检）

    struct ScrollDeltaDetail {
        let dy: Int?
        let fineErr: Double
        let secondErr: Double
        let tex: Int
    }

    /// 求 new 相对 prev 的向上滚动位移（像素行数，0 = 未动，nil = 无法匹配）
    static func scrollDelta(prev: Frame, new: Frame) -> Int? {
        scrollDeltaDetailed(prev: prev, new: new).dy
    }

    /// 带诊断信息的双向匹配：dy>0 内容上移（下滚）/ dy<0 内容下移（上滚）/ 0 静止 / nil 无法匹配。
    /// 正向扫描不通过就交换角色做反向扫描。
    static func scrollDeltaDetailed(prev: Frame, new: Frame) -> ScrollDeltaDetail {
        let fwd = scanOneDirection(prev: prev, new: new)
        if fwd.dy != nil { return fwd }
        let bwd = scanOneDirection(prev: new, new: prev)
        if let k = bwd.dy {
            return ScrollDeltaDetail(dy: -k, fineErr: bwd.fineErr, secondErr: bwd.secondErr, tex: bwd.tex)
        }
        return fwd  // dy=nil，保留正向诊断
    }

    /// 单向匹配（内容上移方向）：纹理闸门（全白/低纹理候选一律不可信）+ 次优解判定
    static func scanOneDirection(prev: Frame, new: Frame) -> ScrollDeltaDetail {
        let none = ScrollDeltaDetail(dy: nil, fineErr: .greatestFiniteMagnitude, secondErr: .greatestFiniteMagnitude, tex: 0)
        let H = prev.h
        guard new.h == H, new.w == prev.w else { return none }
        let maxDelta = H - 60
        guard maxDelta > 0 else { return ScrollDeltaDetail(dy: 0, fineErr: 0, secondErr: 0, tex: 0) }
        // 粗扫（步长 8），记录每个候选 dy 的误差与纹理分
        var errs: [(dy: Int, err: Double, tex: Int)] = []
        var dy = 0
        while dy <= maxDelta {
            errs.append((dy, stripError(prev: prev, new: new, dy: dy),
                         textureScore(prev: prev, new: new, dy: dy)))
            dy += 8
        }
        // 纹理闸门前置：重叠区「高对比像素」太少的候选（全白/纯色对齐）直接出局。
        // 白底页上全白对齐 err=0 会抢到全局最优（实测 dy=340 假对齐挤出真匹配 dy=87），
        // 必须在选优前就过滤，而不是事后否决。
        let eligible = errs.filter { $0.tex >= 24 }
        guard let (best, bestErr, _) = eligible.min(by: { $0.err < $1.err }) else { return none }
        // 次优解（排除最优 ±8 邻域）：低纹理内容（纯色/渐变）各 dy 误差接近，
        // 用「显著优于次优」防止误匹配（手滑上滚/来回滚动的关键防线）
        let secondErr = eligible.filter { abs($0.dy - best) > 8 }.map { $0.err }.min() ?? .greatestFiniteMagnitude
        // 精扫（±8 步长 1）——同样过纹理闸门：
        // 粗选若恰好卡在文字边缘（err 非 0 但有纹理），不加闸门会滑进旁边的全白 err=0 假对齐
        var fine = best, fineErr = bestErr, fineTex = textureScore(prev: prev, new: new, dy: best)
        let lo = max(0, best - 8), hi = min(maxDelta, best + 8)
        if lo <= hi {
            for d in lo...hi {
                let t = textureScore(prev: prev, new: new, dy: d)
                guard t >= 24 else { continue }
                let e = stripError(prev: prev, new: new, dy: d)
                if e < fineErr { fineErr = e; fine = d; fineTex = t }
            }
        }
        let tex = fineTex
        let decisive = fineErr < 1.5 || fineErr < 0.6 * secondErr
        let dyOut: Int? = (fineErr < 6.0 && decisive) ? fine : nil
        return ScrollDeltaDetail(dy: dyOut, fineErr: fineErr, secondErr: secondErr, tex: tex)
    }

    /// 重叠区纹理分：采样点中与右邻像素高对比（|ΔRGB| > 24）的数量
    static func textureScore(prev: Frame, new: Frame, dy: Int) -> Int {
        let overlap = prev.h - dy
        guard overlap > 40 else { return 0 }
        let rowStep = max(2, overlap / 64)
        let colStep = max(4, prev.w / 96)
        var tex = 0
        prev.data.withUnsafeBytes { pBuf in
            new.data.withUnsafeBytes { nBuf in
                let p = pBuf.bindMemory(to: UInt8.self)
                let q = nBuf.bindMemory(to: UInt8.self)
                var r = 0
                while r < overlap {
                    let pr = (dy + r) * prev.bpr
                    let nr = r * new.bpr
                    var c = 4
                    while c < prev.w {
                        let i = pr + c * 4, j = nr + c * 4
                        let dp = abs(Int(p[i]) - Int(p[i - 4])) + abs(Int(p[i + 1]) - Int(p[i - 3])) + abs(Int(p[i + 2]) - Int(p[i - 2]))
                        let dq = abs(Int(q[j]) - Int(q[j - 4])) + abs(Int(q[j + 1]) - Int(q[j - 3])) + abs(Int(q[j + 2]) - Int(q[j - 2]))
                        if dp > 24 || dq > 24 { tex += 1 }
                        c += colStep
                    }
                    r += rowStep
                }
            }
        }
        return tex
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
        win.sharingType = .none          // 对截屏隐身，边框不入长图
        win.isReleasedWhenClosed = false // 默认 true：close() 会自释放，属性再 nil 化 = 双重释放 → pool-pop SIGSEGV
        let bv = ScrollBorderView(frame: NSRect(origin: .zero, size: frame.size))
        win.contentView = bv
        borderView = bv
        win.orderFrontRegardless()
        borderWin = win
    }

    // MARK: - 调试日志（每帧匹配详情，排障用）

    private func debugLog(detail: ScrollDeltaDetail, appended: Int) {
        let line = "\(Date()) dy=\(detail.dy.map(String.init) ?? "nil") err=\(String(format: "%.2f", detail.fineErr)) second=\(String(format: "%.2f", detail.secondErr)) tex=\(detail.tex) append=\(appended) bottom=\(capturedBottom)\n"
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("shotmark-scroll.log")
        guard let d = line.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(d); try? h.close()
        } else {
            try? d.write(to: url)
        }
    }

    // MARK: - 实时拼接预览窗（对标飞书）

    private func updatePreview(force: Bool = false) {
        guard !tornDown else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastPreviewAt) > 0.8 else { return }
        lastPreviewAt = now
        guard let img = compose() else { return }
        if previewWin == nil { makePreviewWindow() }
        previewImgView?.image = img
        let maxW: CGFloat = 340, maxH: CGFloat = 480, pad: CGFloat = 10
        let k = min(maxW / img.size.width, maxH / img.size.height, 1.0)
        let w = max(48, img.size.width * k) + pad * 2
        let h = max(48, img.size.height * k) + pad * 2
        guard let win = previewWin, let bf = borderWin?.frame else { return }
        // 优先放选区右侧，放不下放左侧
        var x = bf.maxX + 12
        if x + w > screen.frame.maxX - 8 { x = bf.minX - 12 - w }
        x = max(screen.frame.minX + 8, x)
        let y = min(bf.maxY - h, screen.frame.maxY - h - 8)
        win.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
        previewImgView?.frame = NSRect(x: 10, y: 10, width: w - 20, height: h - 20)
    }

    private func makePreviewWindow() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                           styleMask: .borderless, backing: .buffered, defer: false)
        win.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.isOpaque = false
        win.backgroundColor = .clear
        win.ignoresMouseEvents = true
        win.sharingType = .none          // 预览窗也不入长图
        win.isReleasedWhenClosed = false // 同上，防双重释放
        let bg = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.85).cgColor
        bg.layer?.cornerRadius = 10
        let iv = NSImageView(frame: NSRect(x: 10, y: 10, width: 180, height: 180))
        iv.imageScaling = .scaleProportionallyUpOrDown
        bg.addSubview(iv)
        win.contentView = bg
        previewImgView = iv
        win.orderFrontRegardless()
        previewWin = win
    }
}

/// 选区边框（虚线蓝）+ 顶部操作提示（含已拼接长度）
final class ScrollBorderView: NSView {
    var progress: Int = 0 {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        // 顶部提示条
        let hint = progress > 0
            ? "滚动截屏中 · 已拼 \(progress)px · 空格/回车 完成 · Esc 取消"
            : "滚动截屏进行中 · 滚动滚轮 · 空格/回车 完成 · Esc 取消"
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
