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

        /// 降采样构造（重锚定粗搜用）：把 cg 画进 scale 倍小位图
        init(_ cg: CGImage, downscale: CGFloat) {
            let w = max(1, Int((CGFloat(cg.width) * downscale).rounded()))
            let h = max(1, Int((CGFloat(cg.height) * downscale).rounded()))
            let bpr = w * 4
            var d = Data(count: h * bpr)
            d.withUnsafeMutableBytes { ptr in
                guard let base = ptr.baseAddress,
                      let ctx = CGContext(data: base, width: w, height: h,
                                          bitsPerComponent: 8, bytesPerRow: bpr,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
                ctx.interpolationQuality = .high
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            self.cg = cg
            self.w = w
            self.h = h
            self.bpr = bpr
            self.data = d
        }

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
    private let snapshot: NSImage?         // 会话开始时的全屏快照（暗色层用，nil = 不画暗色层）
    private let onFinish: (NSImage?) -> Void

    private var borderWin: NSWindow?
    private weak var borderView: ScrollBorderView?
    private var previewWin: NSWindow?
    private weak var previewImgView: NSImageView?
    private var lastPreviewAt = Date.distantPast
    private var timer: Timer?
    private var tickInterval: Double = 0   // 速度自适应：滚得快就抓得快。初值必须是 0——若等于首个调度值，scheduleTimer 的「没变不重建」守卫会把初始定时器吃掉（实测事故：滚动会话定时器从未创建，只有第一帧处理，永不拼接）
    private var capturing = false
    private var hotKeyRefs: [EventHotKeyRef?] = []
    private var nilStreak = 0                  // 连续配不上且内容在变的拍数（失速预警）

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
    /// 自检用：当前锚定位置
    var debugLastPos: Int { lastPos }
    /// 自检时关掉落盘日志（避免污染正式 shotmark-scroll.log）
    var loggingEnabled = true
    /// 重锚定缓存（segments 变化即失效）
    private var accCache: (cg: CGImage, small: Frame, top: Int, bottom: Int)?
    var reanchorMinInterval: Double = 1.2   // 测试可设 0
    private var lastReanchorAt = Date.distantPast
    /// 已销毁：阻断 finish/cancel 重入与 in-flight 抓帧复活窗口
    private var tornDown = false

    init(screen: NSScreen, regionPts: CGRect, snapshot: NSImage? = nil, onFinish: @escaping (NSImage?) -> Void) {
        self.screen = screen
        self.regionPts = regionPts
        self.snapshot = snapshot
        self.onFinish = onFinish
    }

    // MARK: - 生命周期

    func start() {
        showBorder()
        // 清单缓存作废：边框窗刚刚创建，抓帧的排除列表必须带上它（否则会把自己抓进长图）
        Capture.invalidateContentCache()
        hotKeyRefs = HotKey.registerRaw(keys: [49, 36, 53]) { [weak self] code in
            guard let self = self else { return }
            if code == 53 { self.cancel() } else { self.finish() }
        }
        scheduleTimer(0.15)
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

    private func scheduleTimer(_ interval: Double) {
        guard interval != tickInterval else { return }
        tickInterval = interval
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    /// 失速自救：把当前帧到整幅已拼长图里重锚定。
    /// 用户快滚甩过头（位移超出帧间量程）后，只要回滚到已拼过的任何位置，就能认出并续接。
    /// 粗搜在 1/4 降采样长图上做（步长 8 小行 = 32 全行），命中后用既有的全分辨率闸门匹配器验证。
    private func tryReanchor(nf: Frame, force: Bool = false) -> (Frame, Int, ScrollDeltaDetail)? {
        guard force || Date().timeIntervalSince(lastReanchorAt) > reanchorMinInterval else { return nil }
        let totalH = capturedBottom - capturedTop
        guard totalH > nf.h else { return nil }   // 长图还没一帧高，无从锚起
        lastReanchorAt = Date()

        // 缓存失效则重建（compose 一次不便宜，仅失速时来）
        if accCache == nil {
            guard let img = compose(), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
            accCache = (cg, Frame(cg, downscale: 0.25), capturedTop, capturedBottom)
        }
        guard let acc = accCache, acc.top == capturedTop, acc.bottom == capturedBottom else { return nil }

        let accSmall = acc.small
        let fSmall = Frame(nf.cg, downscale: 0.25)
        let smallH = fSmall.h
        let accRows = accSmall.h
        let minOv = smallH / 4
        guard accRows >= smallH + 8 else { return nil }

        // 粗搜：在长图（小尺度）上滑窗找最优位置
        var bestOff = -1, bestErr = Double.greatestFiniteMagnitude
        var off = 0
        let maxOff = accRows - smallH
        while off <= maxOff {
            let e = Self.errAtOffset(acc: accSmall, nf: fSmall, off: off)
            if e < bestErr { bestErr = e; bestOff = off }
            off += 8
        }
        guard bestOff >= 0, bestErr < 8.0 else { return nil }

        // 全分辨率验证：裁长图对应切片，走既有的五闸门匹配器
        let pos = capturedTop + bestOff * 4
        let sliceTop = min(max(capturedTop, pos - 32), capturedBottom - nf.h)
        guard let sliceCG = acc.cg.cropping(to: CGRect(x: 0, y: sliceTop - capturedTop, width: nf.w, height: nf.h)) else { return nil }
        let sliceFrame = Frame(sliceCG)
        let detail = Self.scrollDeltaDetailed(prev: sliceFrame, new: nf)
        guard detail.dy != nil else { return nil }
        return (sliceFrame, sliceTop, detail)
    }

    /// 小尺度偏置误差：acc 的 [off, off+nf.h) vs nf 的 [0, nf.h)
    private static func errAtOffset(acc: Frame, nf: Frame, off: Int) -> Double {
        let overlap = nf.h
        let rowStep = max(1, overlap / 48)
        let colStep = max(2, nf.w / 64)
        var sum = 0.0, n = 0.0
        acc.data.withUnsafeBytes { aBuf in
            nf.data.withUnsafeBytes { nBuf in
                let a = aBuf.bindMemory(to: UInt8.self)
                let b = nBuf.bindMemory(to: UInt8.self)
                var r = 0
                while r < overlap {
                    let ar = (off + r) * acc.bpr
                    let nr = r * nf.bpr
                    var c = 0
                    while c < nf.w {
                        let i = ar + c * 4, j = nr + c * 4
                        sum += Double(abs(Int(a[i]) - Int(b[j])) + abs(Int(a[i+1]) - Int(b[j+1])) + abs(Int(a[i+2]) - Int(b[j+2])))
                        n += 3
                        c += colStep
                    }
                    r += rowStep
                }
            }
        }
        return n > 0 ? sum / n : .greatestFiniteMagnitude
    }

    /// 位移大 = 用户在快滚 → 抓帧提速到 70ms；慢下来回 150ms。
    /// 否则惯性滚动的单拍位移会超出匹配量程（maxDelta），永失衔接（静默丢内容）。
    private func adaptTickRate(matchedDy: Int, frameH: Int) {
        if matchedDy > frameH / 4 {
            scheduleTimer(0.07)
        } else if matchedDy < frameH / 8 {
            scheduleTimer(0.15)
        }
    }

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
        if ProcessInfo.processInfo.environment["SM_DEBUG"] == "1" {
            let dyStr = detail.dy.map { String($0) } ?? "nil"
            let errStr = String(format: "%.2f", detail.fineErr)
            let l = "SM tick: nilStreak=" + String(nilStreak) + " lastPos=" + String(lastPos)
                + " cB=" + String(capturedBottom) + " dy=" + dyStr + " err=" + errStr
            fputs(l + "\n", stderr)
        }
        guard let dy = detail.dy else {
            // 未匹配（滚轮惯性甩快/低纹理）。恢复顺序：
            // ① 长图底部带重定位（惯性快滚后新帧通常仍与长图底部有重叠）
            // ② 全图重锚定（用户回滚到已拼区域上部的情况）
            // ③ 都失败：保留最新帧作下拍参照（内容在动，旧参照只会更远），计失速等用户回滚
            if let o = relocateAgainstBottomBand(nf: nf) {
                let ap = applyMatch(dy: o - lastPos, nf: nf)
                nilStreak = 0
                borderView?.warning = nil
                let line = "[ShotMark] relocated(nil-path): o=" + String(o) + " append=" + String(ap)
                fputs(line + "\n", stderr)
                return
            }
            if let (slice, pos, d2) = tryReanchor(nf: nf), let dy2 = d2.dy {
                lastFrame = slice
                lastPos = pos
                let ap = applyMatch(dy: dy2, nf: nf)
                nilStreak = 0
                borderView?.warning = nil
                debugLog(detail: d2, appended: ap)
                return
            }
            let staticErr = Self.stripError(prev: prev, new: nf, dy: 0)
            if nilStreak >= 3 {
                // 连续 3 拍锚不上 = 内容确实跳变了（甩太快/页面跳转）。
                // 接受不连续：整帧拼在长图尾部（有可见跳变但内容不丢），重置锚定继续
                let ap = applyMatch(dy: capturedBottom - lastPos, nf: nf)
                nilStreak = 0
                borderView?.warning = "检测到画面跳变，长图此处不连续"
                let line = "[ShotMark] discontinuity accepted: append=" + String(ap)
                fputs(line + "\n", stderr)
                debugLog(detail: detail, appended: ap)
                return
            }
            nilStreak = staticErr > 8 ? min(nilStreak + 1, 50) : 0
            lastFrame = nf   // 保留最新帧：内容在动，旧参照只会更远（nilStreak>0 标记位置未知）
            borderView?.warning = nilStreak >= 5
                ? "衔接丢失 · 回滚到已拼过的画面即可自动续接"
                : nil
            debugLog(detail: detail, appended: 0)
            return
        }
        // 跳帧恢复（滚轮惯性场景实测断缝根因）：期间有过 dy=nil，lastFrame 已过期——
        // 对过期参照匹配出的 dy 不可信，必须先对「长图底部带」重定位拿绝对位置；
        // 候选新增若与长图邻域对齐 = 已拼内容的重复（来回滚歧义定位），只校准账本不拼
        var vdy = dy
        if nilStreak > 0 {
            // 跳帧后 lastFrame 已过期，对它的匹配不可信——改对「长图底部带」重定位：
            // 在新帧里找长图底边的真实落点，直接得到绝对位置（不依赖 accCache/节流）
            if let o = relocateAgainstBottomBand(nf: nf) {
                let newBelow = (o + nf.h) - capturedBottom
                let newAbove = capturedTop - o
                if newBelow > 40 {
                    if duplicateNearBottom(nf: nf, o: o) {
                        // 已拼内容的重复：不拼，只把账本校准到真实位置
                        lastFrame = nf
                        lastPos = o
                        nilStreak = 0
                        borderView?.warning = nil
                        let line = "[ShotMark] dup-bottom: o=" + String(o) + " 跳过重复拼接"
                        fputs(line + "\n", stderr)
                        return
                    }
                    vdy = o - lastPos
                    let line = "[ShotMark] relocated: o=" + String(o) + " vdy=" + String(vdy)
                    fputs(line + "\n", stderr)
                } else if newAbove > 40 {
                    if duplicateNearTop(nf: nf, o: o) {
                        lastFrame = nf
                        lastPos = o
                        nilStreak = 0
                        let line = "[ShotMark] dup-top: o=" + String(o) + " 跳过重复前插"
                        fputs(line + "\n", stderr)
                        return
                    }
                    vdy = o - lastPos
                } else {
                    // 纯重游（整帧在已拼区域内）：只校准账本
                    lastFrame = nf
                    lastPos = o
                    nilStreak = 0
                    return
                }
            } else {
                // 新帧与长图无重叠（甩太远）或找不到锚点：诚实放弃这一帧
                nilStreak = min(nilStreak + 1, 50)
                debugLog(detail: detail, appended: 0)
                return
            }
        }
        let appended = applyMatch(dy: vdy, nf: nf)
        debugLog(detail: detail, appended: appended)
    }

    /// 从 segments 组装长图的 [absTop, absTop+height) 行段（行级拷贝，零坐标系歧义）
    private func compositeRows(_ absTop: Int, _ height: Int) -> Frame? {
        let absBottom = absTop + height
        guard absTop >= capturedTop, absBottom <= capturedBottom, let first = segments.first else { return nil }
        let w = first.1.width
        let bpr = w * 4
        var data = [UInt8](repeating: 235, count: bpr * height)
        for (pos, cg) in segments {
            let seg = Frame(cg)
            let lo = max(pos, absTop)
            let hi = min(pos + seg.h, absBottom)
            guard hi > lo else { continue }
            let srcStart = (lo - pos) * seg.bpr
            let len = (hi - lo) * seg.bpr
            let piece = seg.data.subdata(in: srcStart..<srcStart+len)
            let dstStart = (lo - absTop) * bpr
            data.replaceSubrange(dstStart..<dstStart+len, with: piece)
        }
        return frameFromRows(data, w: w, h: height)
    }

    private func bottomBandFrame(_ B: Int) -> (Frame, Int)? {
        guard capturedBottom - capturedTop >= B else { return nil }
        let top = capturedBottom - B
        return compositeRows(top, B).map { ($0, top) }
    }

    /// 重复检测：候选新增头部若能与长图尾部邻域（capturedBottom - 2H … capturedBottom）任一偏移对齐，
    /// 则为已拼内容的重复（均匀列表来回滚的歧义定位所致），不拼。
    private func duplicateNearBottom(nf: Frame, o: Int) -> Bool {
        let headTop = capturedBottom
        let len = min(220, o + nf.h - headTop)
        guard len >= 60, let candCG = nf.cg.cropping(to: CGRect(x: 0, y: headTop - o, width: nf.w, height: len)) else { return false }
        let cand = Frame(candCG)
        let searchTop = max(capturedTop, capturedBottom - 2 * nf.h)
        guard let ref = compositeRows(searchTop, capturedBottom - searchTop) else { return false }
        var best = Double.greatestFiniteMagnitude
        var off = 0
        let maxOff = ref.h - len
        while off <= maxOff {
            let e = Self.stripErrorInk(prev: ref, new: cand, dy: off, rowLo: 0, rowHi: len - 1)
            if e < best { best = e }
            off += 8
        }
        let line = "[ShotMark] dupBottom check: best=" + String(format: "%.2f", best)
        fputs(line + "\n", stderr)
        return best < 60
    }

    /// 重复检测（前插方向）：候选前插内容若能与长图头部对齐，则为重复
    private func duplicateNearTop(nf: Frame, o: Int) -> Bool {
        let len = min(220, capturedTop - o)
        guard len >= 60, let candCG = nf.cg.cropping(to: CGRect(x: 0, y: 0, width: nf.w, height: len)) else { return false }
        let cand = Frame(candCG)
        let searchH = min(capturedBottom - capturedTop, 2 * nf.h)
        guard let ref = compositeRows(capturedTop, searchH) else { return false }
        var best = Double.greatestFiniteMagnitude
        var off = 0
        let maxOff = ref.h - len
        while off <= maxOff {
            let e = Self.stripErrorInk(prev: ref, new: cand, dy: off, rowLo: 0, rowHi: len - 1)
            if e < best { best = e }
            off += 8
        }
        return best < 60
    }

    /// 跳帧恢复：把长图底部带（末 B 行）在新帧里重定位，返回新帧顶部的绝对位置 o。
    /// 找不到（无重叠/歧义）返回 nil。带从 segments 现场绘制，不依赖 accCache/节流。
    private func relocateAgainstBottomBand(nf: Frame) -> Int? {
        let B = min(300, max(120, capturedBottom - capturedTop))
        let dbg2 = ProcessInfo.processInfo.environment["SM_DEBUG"] == "1"
        if dbg2 {
            let l = "[ShotMark] relocate enter: B=" + String(B) + " nf=" + String(nf.w) + "x" + String(nf.h)
                + " cT=" + String(capturedTop) + " cB=" + String(capturedBottom)
                + " segs=" + String(segments.count)
            fputs(l + "\n", stderr)
        }
        guard capturedBottom - capturedTop >= B + 60,
              let (band, bandTop) = bottomBandFrame(B) else { return nil }
        // 带底边在新帧内的落点 rEnd ∈ [60, nf.h]；对应帧顶 abs 位置 o = capturedBottom - rEnd
        var bestR = -1
        var bestErr = Double.greatestFiniteMagnitude
        var errSum = 0.0
        var errN = 0
        // rEnd ∈ [60, nf.h-60]：新帧与长图至少 60px 真实重叠（防跳帧大间隙的伪锚点）
        var rEnd = 60
        let rEndMax = max(60, nf.h - 60)
        while rEnd <= rEndMax {
            let e = bandSeamErr(band: band, nf: nf, rEnd: rEnd)
            if e < bestErr { bestErr = e; bestR = rEnd }
            errSum += e; errN += 1
            rEnd += 2      // 恢复路径用细步长：真对齐可能落在任意行（步长 8 会跳过，实测 rEnd=140 漏检）
        }
        // 精扫 ±8
        if bestR > 0 {
            var r = max(60, bestR - 8)
            let hi = min(nf.h - 60, bestR + 8)
            while r <= hi {
                let e = bandSeamErr(band: band, nf: nf, rEnd: r)
                if e < bestErr { bestErr = e; bestR = r }
                r += 1
            }
        }
        // 锐利最小值判据：真对齐 = 尖锐全局最小（bestErr ≪ 平均）；伪锚点（新帧不含带，
        // 平滑渐变上随便哪都半像）误差曲线平缓，bestErr ≈ 平均 → 拒绝
        let meanErr = errN > 0 ? errSum / Double(errN) : .greatestFiniteMagnitude
        let dbg = ProcessInfo.processInfo.environment["SM_DEBUG"] == "1"
        if dbg {
            let l = "[ShotMark] relocate: bestR=" + String(bestR) + " bestErr=" + String(format: "%.2f", bestErr)
                + " meanErr=" + String(format: "%.2f", meanErr)
                + " bandTop=" + String(capturedBottom - B) + " cB=" + String(capturedBottom)
            fputs(l + "\n", stderr)
        }
        guard bestR > 0, bestErr < 150, bestErr < 0.5 * meanErr else { return nil }
        return capturedBottom - bestR
    }


    /// 从 top-origin 行数据组装 Frame（缓冲快照，零坐标系歧义）
    private func frameFromRows(_ data: [UInt8], w: Int, h: Int) -> Frame? {
        var d = data
        let bpr = w * 4
        var cgOut: CGImage?
        d.withUnsafeMutableBytes { ptr in
            guard let base = ptr.baseAddress,
                  let ctx = CGContext(data: base, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: bpr,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            cgOut = ctx.makeImage()
        }
        guard let cg = cgOut else { return nil }
        return Frame(cg)
    }

    /// 带底部 L 行 vs 新帧 [rEnd-L, rEnd) 的墨迹加权误差
    private func bandSeamErr(band: Frame, nf: Frame, rEnd: Int) -> Double {
        let L = min(band.h, rEnd)
        guard L >= 40 else { return .greatestFiniteMagnitude }
        // stripErrorInk 比较 prev[dy+r] vs new[r]：配对 band[band.h-L+t] ↔ nf[rEnd-L+t] → dy = band.h - rEnd
        return Self.stripErrorInk(prev: band, new: nf, dy: band.h - rEnd, rowLo: rEnd - L, rowHi: rEnd - 1)
    }

    private var nfWidth: Int { segments.first?.1.width ?? 0 }

    /// 把一次匹配结果落到水位线/片段上（主匹配与重锚定共用）


    /// 跳帧恢复的接缝验证：新帧与长图重叠部分，必须和长图底部实际内容一致。
    /// 通过 → 返回原 dy；不符/无法验证且风险高 → nil（调用方强制重锚定）。
    private func verifySeam(nf: Frame, dy: Int) -> Int? {
        guard let acc = accCache, acc.top == capturedTop, acc.bottom == capturedBottom else { return dy }
        let pAbs = lastPos + dy
        guard pAbs + nf.h > capturedBottom else { return dy }   // 整帧都在已拼区域内（重游）：无接缝
        var L = min(300, nf.h, capturedBottom - pAbs)
        guard L >= 60 else { return nil }                        // 与长图重叠不足：证据不够，须重锚定
        var nfLo = capturedBottom - pAbs - L
        if nfLo < 0 { L += nfLo; nfLo = 0 }
        guard L >= 60,
              let bandCG = acc.cg.cropping(to: CGRect(x: 0, y: acc.cg.height - L, width: nf.w, height: L)),
              let nfCG = nf.cg.cropping(to: CGRect(x: 0, y: nfLo, width: nf.w, height: L)) else { return nil }
        let band = Frame(bandCG)
        let nfPart = Frame(nfCG)
        let seamErr = Self.stripError(prev: band, new: nfPart, dy: 0)
        let line = "[ShotMark] seam verify: L=" + String(L) + " err=" + String(format: "%.2f", seamErr)
            + (seamErr <= 3.0 ? " pass" : " FAIL -> reanchor")
        fputs(line + "\n", stderr)
        return seamErr <= 3.0 ? dy : nil
    }

    /// 把一次匹配结果落到水位线/片段上（主匹配与重锚定共用）
    @discardableResult
    private func applyMatch(dy: Int, nf: Frame) -> Int {
        nilStreak = 0
        borderView?.warning = nil
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
            accCache = nil                          // 长图变了，重锚定缓存失效
            borderView?.progress = capturedBottom - capturedTop
            updatePreview()
        }
        adaptTickRate(matchedDy: abs(dy), frameH: nf.h)
        lastPos = p
        lastFrame = nf
        return appended
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
        let dy: Int?        // >0 下滚（底部新增 dy 行）/ <0 上滚（顶部新增 -dy 行）/ 0 静止 / nil 无法匹配
        let fineErr: Double // 最优候选的平均像素差
        let secondErr: Double // 次优候选误差（判 decisiveness 用）
        let tex: Int        // 重叠区纹理分
    }

    /// 带诊断信息的双向匹配（v5：模糊匹配 + 幻影全套闸门）。
    /// 选型弯路存档：v3 模糊（会幻影：dy=660 顶边界 err5.95 擦边过线）→ v4 近似精确
    ///（滚动动画/亚像素变化页恒 nil）→ v5 = 模糊 + 四条幻影闸门（全部由真实事故反推）：
    /// ① 纹理闸门：候选先按重叠区高对比像素 ≥48 过滤（全白 err=0 假对齐在选优前出局；阈值 48 是实测校准——白底稀疏文本页合法匹配 tex 104+，字形出血幻影只有 24-35）
    /// ② 边界否决：贴 maxDelta 边界的候选（位移顶满扫描范围=多半是真位移超出量程的错配），
    ///    必须 err<1.5 近乎全等才放行（幻影 660 死在这条）
    /// ③ 次优解判定：恒要求 fineErr < 0.6×secondErr，无豁免（渐变/低纹理/白底假匹配死在这条）
    /// ④ 阈值 fineErr < 5.0（抗滚动动画噪声，又不放过大面积错位）
    /// 双向：正向（内容上移/下滚）配不上再反向扫，两向都有效时取 fineErr 更小者。
    static func scrollDeltaDetailed(prev: Frame, new: Frame) -> ScrollDeltaDetail {
        let fwd = scanOneDirection(prev: prev, new: new)
        let bwdRaw = scanOneDirection(prev: new, new: prev)   // 交换角色 = 反向（内容下移/上滚）
        let bwd: ScrollDeltaDetail = bwdRaw.dy.map {
            ScrollDeltaDetail(dy: -$0, fineErr: bwdRaw.fineErr, secondErr: bwdRaw.secondErr, tex: bwdRaw.tex)
        } ?? bwdRaw
        if fwd.dy != nil, bwd.dy != nil {
            // 重叠大者优先（位移更小、证据更多；噪声帧上幻影 err 更低是常态，纯 err 竞争会被带偏），
            // 但另一向 err 显著更低（< 0.5×）时以 err 为准——均匀列表正反都能「对上」，
            // 重叠大的可能是错周期/错位置（stitch 第三缝 fwd76 挤掉真 -84 事故）
            let fwdOv = prev.h - abs(fwd.dy ?? 0)
            let bwdOv = prev.h - abs(bwd.dy ?? 0)
            let fe = fwd.fineErr ?? .greatestFiniteMagnitude
            let be = bwd.fineErr ?? .greatestFiniteMagnitude
            if fwdOv >= bwdOv {
                return be < 0.5 * fe ? bwd : fwd
            } else {
                return fe < 0.5 * be ? fwd : bwd
            }
        }
        return fwd.dy != nil ? fwd : bwd
    }

    static func scrollDelta(prev: Frame, new: Frame) -> Int? {
        scrollDeltaDetailed(prev: prev, new: new).dy
    }

    /// 单向扫描（内容上移方向）：prev 的下部 vs new 的上部
    private static func scanOneDirection(prev: Frame, new: Frame) -> ScrollDeltaDetail {
        let none = ScrollDeltaDetail(dy: nil, fineErr: .greatestFiniteMagnitude, secondErr: .greatestFiniteMagnitude, tex: 0)
        let H = prev.h
        guard new.h == H, new.w == prev.w else { return none }
        // 闸门①：最小重叠 = max(100, H/4)。位移越大需要的重叠证据越多——
        // 大位移+小重叠在均匀列表上等于没有证据（成员列表页 dy=621 重叠仅 9% 事故）
        let minOverlap = max(100, H / 4)
        let maxDelta = H - minOverlap
        guard maxDelta > 0 else { return ScrollDeltaDetail(dy: 0, fineErr: 0, secondErr: 0, tex: 0) }
        // 粗扫（步长 8）：纹理闸门先行，候选 tex<24 直接出局
        var errs: [(dy: Int, err: Double)] = []
        var dy = 0
        while dy <= maxDelta {
            if textureScore(prev: prev, new: new, dy: dy) >= 48 {
                errs.append((dy, stripError(prev: prev, new: new, dy: dy)))
            }
            dy += 8
        }
        guard let (best, bestErr) = errs.min(by: { $0.err < $1.err }) else { return none }
        let secondErr = errs.filter { abs($0.dy - best) > 8 }.map { $0.err }.min() ?? .greatestFiniteMagnitude
        // 精扫（±8 步长 1）
        var fine = best, fineErr = bestErr
        let lo = max(0, best - 8), hi = min(maxDelta, best + 8)
        if lo <= hi {
            for d in lo...hi where textureScore(prev: prev, new: new, dy: d) >= 48 {
                let e = stripError(prev: prev, new: new, dy: d)
                if e < fineErr { fineErr = e; fine = d }
            }
        }
        let tex = textureScore(prev: prev, new: new, dy: fine)

        // 闸门⑤：三带一致性。重叠区分三带各自验误差，任一带 err > max(3.0, fineErr*3) 即拒绝。
        // 均匀列表（卡片等高）会让错误周期在全局均值上低误差命中——独特内容（地标行）的
        // 高误差被白底稀释（成员列表页尾部拼错事故：dy 偏半张卡，全局 err 仅 1.24/1.51）
        // 闸门⑤：三带独立最优判定（均匀列表防错周期）。
        // 重叠区分三带，各带在全域（跳出全局 dy ±8）用墨迹误差找自己的最优 dy；
        // 某带的全局最优显著优于它在全局 dy 处的误差（< 0.5×）= 该带与全局 dy 不一致 → 拒绝。
        // 与「带间 max/min 比值」规则的区别：墨迹分布不均的页面（文字密集带 vs 空白带）
        // 不会误伤——对齐的带在别处不会更优。成员列表页尾部拼错事故的最终修复。
        let overlap = H - fine
        if overlap >= 120 {
            let bandH = overlap / 3
            for b in 0..<3 {
                let lo = fine + b * bandH
                let hi = (b == 2) ? overlap - 1 : (fine + (b + 1) * bandH - 1)
                let eAtFine = stripErrorInk(prev: prev, new: new, dy: fine, rowLo: lo, rowHi: hi)
                guard eAtFine > 30 else { continue }   // 这带已近乎全等，无需检查
                // 该带在双向全域找自己的最优 dy（负 dy 时 prev 行号 d+r 需在界内，按交集裁剪）
                var best = eAtFine
                var d = -maxDelta
                while d <= maxDelta {
                    if abs(d - fine) > 8 {
                        let lo2 = max(lo, -d)
                        let hi2 = min(hi, H - 1 - d)
                        if hi2 - lo2 >= 20 {
                            let e = stripErrorInk(prev: prev, new: new, dy: d, rowLo: lo2, rowHi: hi2)
                            if e < best { best = e }
                        }
                    }
                    d += 8
                }
                if best < 0.5 * eAtFine && best < 150 { return none }
            }
        }

        // 闸门②：贴边界的候选必须是近乎全等
        if abs(fine - maxDelta) <= 8 || fine <= 8 {
            guard fineErr < 1.5 else { return none }
        }
        // 闸门③④：恒要求显著优于次优解（白底页 err 地形平坦，「几乎全等」豁免会让幻影钻进来——
        // 实测幻影 dy=312 err1.74 second2.91 恰好靠豁免过线；真匹配的 secondErr 都很大）
        let decisive = fineErr < 0.6 * secondErr
        let dyOut: Int? = (fineErr < 150 && decisive && tex >= 48) ? fine : nil
        return ScrollDeltaDetail(dy: dyOut, fineErr: fineErr, secondErr: secondErr, tex: tex)
    }

    /// 重叠区纹理分：采样点中与右邻像素高对比（|ΔRGB| > 24）的数量，双侧取小。
    /// 取小是关键：单侧出血（字形边缘探进白色重叠区）不算纹理——实测幻影就靠单侧出血骗过单侧口径
    static func textureScore(prev: Frame, new: Frame, dy: Int) -> Int {
        let overlap = prev.h - dy
        guard overlap > 40 else { return 0 }
        let rowStep = max(2, overlap / 64)
        let colStep = max(4, prev.w / 96)
        var texA = 0, texB = 0
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
                        if dp > 24 { texA += 1 }
                        if dq > 24 { texB += 1 }
                        c += colStep
                    }
                    r += rowStep
                }
            }
        }
        return min(texA, texB)
    }

    /// prev 的 [dy..H) 与 new 的 [0..H-dy) 的平均像素差（抽样）
    /// 重叠区指定行段 [rowLo, rowHi]（含两端，相对重叠区顶部）的平均像素差
    static func stripErrorRange(prev: Frame, new: Frame, dy: Int, rowLo: Int, rowHi: Int) -> Double {
        let rows = rowHi - rowLo + 1
        guard rows >= 8 else { return .greatestFiniteMagnitude }
        let rowStep = max(1, rows / 32)
        let colStep = max(4, prev.w / 96)
        var sum = 0.0, n = 0.0
        prev.data.withUnsafeBytes { pBuf in
            new.data.withUnsafeBytes { nBuf in
                let p = pBuf.bindMemory(to: UInt8.self)
                let q = nBuf.bindMemory(to: UInt8.self)
                var r = rowLo
                while r <= rowHi {
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

    /// 墨迹加权误差：只统计「至少一侧有墨迹」（亮度 < 210）的采样对。
    /// 白底配白底不携带配准信息——不剔除的话均匀列表上错位文字的代价被白底稀释（拼错事故根因）。
    /// 墨迹样本不足时退回普通均值。
    static func stripErrorInk(prev: Frame, new: Frame, dy: Int, rowLo: Int, rowHi: Int) -> Double {
        let rows = rowHi - rowLo + 1
        guard rows >= 8 else { return .greatestFiniteMagnitude }
        let rowStep = max(1, rows / 32)
        let colStep = max(4, prev.w / 96)
        var inkSum = 0.0, inkN = 0.0
        prev.data.withUnsafeBytes { pBuf in
            new.data.withUnsafeBytes { nBuf in
                let p = pBuf.bindMemory(to: UInt8.self)
                let q = nBuf.bindMemory(to: UInt8.self)
                var r = rowLo
                while r <= rowHi {
                    let pr = (dy + r) * prev.bpr
                    let nr = r * new.bpr
                    var c = 0
                    while c < prev.w {
                        let i = pr + c * 4, j = nr + c * 4
                        let pLum = (Int(p[i]) + Int(p[i+1]) + Int(p[i+2])) / 3
                        let qLum = (Int(q[i]) + Int(q[i+1]) + Int(q[i+2])) / 3
                        if min(pLum, qLum) < 210 {
                            inkSum += Double(abs(Int(p[i]) - Int(q[j]))
                                            + abs(Int(p[i + 1]) - Int(q[j + 1]))
                                            + abs(Int(p[i + 2]) - Int(q[j + 2])))
                            inkN += 3
                        }
                        c += colStep
                    }
                    r += rowStep
                }
            }
        }
        if inkN >= 60 { return inkSum / inkN }
        return stripErrorRange(prev: prev, new: new, dy: dy, rowLo: rowLo, rowHi: rowHi)
    }

    static func stripError(prev: Frame, new: Frame, dy: Int) -> Double {
        let overlap = prev.h - dy
        guard overlap > 40 else { return .greatestFiniteMagnitude }
        return stripErrorRange(prev: prev, new: new, dy: dy, rowLo: 0, rowHi: overlap - 1)
    }


    // MARK: - 调试日志（每帧匹配详情，排障用）

    private func debugLog(detail: ScrollDeltaDetail, appended: Int) {
        guard loggingEnabled else { return }
        let line = "\(Date()) dy=\(detail.dy.map(String.init) ?? "nil") err=\(String(format: "%.2f", detail.fineErr)) second=\(String(format: "%.2f", detail.secondErr)) tex=\(detail.tex) append=\(appended) bottom=\(capturedBottom)\n"
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("shotmark-scroll.log")
        guard let d = line.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(d); try? h.close()
        } else {
            try? d.write(to: url)
        }
    }

    // MARK: - 全屏暗色层（含选区挖洞 + 边框 + 提示条）

    /// 与截图覆盖层交互一致：全屏静态快照 + 选区外暗色 + 选区挖洞（洞内是实时滚动的真内容）。
    /// 窗口 ignoresMouseEvents（滚轮/点击穿透给下方 App）+ sharingType=.none + 清单排除，三保险不入长图。
    private func showBorder() {
        let win = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        win.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.isOpaque = false
        win.backgroundColor = .clear
        win.ignoresMouseEvents = true
        win.sharingType = .none
        win.isReleasedWhenClosed = false // 默认 true：close() 会自释放，属性再 nil 化 = 双重释放 → pool-pop SIGSEGV
        let bv = ScrollBorderView(frame: NSRect(origin: .zero, size: screen.frame.size),
                                  region: regionPts, snapshot: snapshot)
        win.contentView = bv
        borderView = bv
        win.orderFrontRegardless()
        borderWin = win
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

/// 全屏暗色层：静态快照 + 选区挖洞 + 虚线边框（外移 3pt，线宽不压选区）+ 提示条
final class ScrollBorderView: NSView {
    let region: CGRect            // 选区（视图坐标 = 屏内点坐标）
    let snapshot: NSImage?

    var progress: Int = 0 {
        didSet { needsDisplay = true }
    }
    /// 失速预警文案（非 nil 时提示条变红）
    var warning: String? {
        didSet { needsDisplay = true }
    }

    init(frame f: NSRect, region: CGRect, snapshot: NSImage?) {
        self.region = region
        self.snapshot = snapshot
        super.init(frame: f)
    }
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func draw(_ dirtyRect: NSRect) {
        // 静态快照 + 暗色都只画在选区外（选区内必须真透明，露出下方实时滚动的内容）
        NSGraphicsContext.saveGraphicsState()
        let outside = NSBezierPath(rect: bounds)
        outside.append(NSBezierPath(rect: region))
        outside.windingRule = .evenOdd
        outside.addClip()
        snapshot?.draw(in: bounds)
        NSColor.black.withAlphaComponent(0.45).setFill()
        NSBezierPath(rect: bounds).fill()
        NSGraphicsContext.restoreGraphicsState()

        // 虚线边框：整体外移 3pt，2pt 线宽完全落在选区外（不再被截进长图）
        let br = region.insetBy(dx: -3, dy: -3)
        let path = NSBezierPath(rect: br)
        let dash: [CGFloat] = [8, 6]
        path.setLineDash(dash, count: 2, phase: 0)
        NSColor(srgbRed: 0.13, green: 0.59, blue: 0.95, alpha: 1).setStroke()
        path.lineWidth = 2
        path.stroke()

        // 提示条：贴选区上边，没地方就放下边
        let hint = warning ?? (progress > 0
            ? "滚动截屏中 · 已拼 \(progress)px · 空格/回车 完成 · Esc 取消"
            : "滚动截屏进行中 · 滚动滚轮 · 空格/回车 完成 · Esc 取消")
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let ts = NSString(string: hint).size(withAttributes: attrs)
        let barW = ts.width + 20
        let bx = min(max(8, region.midX - barW / 2), bounds.width - barW - 8)
        var by = br.maxY + 8
        if by + 24 > bounds.height - 8 { by = br.minY - 32 }
        let bar = NSRect(x: bx, y: by, width: barW, height: 24)
        (warning == nil ? NSColor(white: 0.1, alpha: 0.9)
                        : NSColor(srgbRed: 0.75, green: 0.2, blue: 0.18, alpha: 0.95)).setFill()
        NSBezierPath(roundedRect: bar, xRadius: 7, yRadius: 7).fill()
        NSString(string: hint).draw(at: CGPoint(x: bar.minX + 10, y: bar.minY + 5), withAttributes: attrs)
    }
}

