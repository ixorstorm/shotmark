// 自动滚动长截图驱动：定时发小步长合成滚轮事件 + 抓帧喂拼接会话
// 飞书同款做法：工具控制滚动步长 → 每帧重叠巨大 → 定位永远命中，均匀列表不再歧义
// 需要辅助功能权限（CGEventPost）
import AppKit
import CoreGraphics

enum Accessibility {
    /// 是否已授权辅助功能；prompt = true 时弹系统授权引导
    static func trusted(prompt: Bool = false) -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }
}

final class AutoScrollDriver {
    private unowned let session: ScrollCaptureSession
    private let screen: NSScreen
    private let region: CGRect
    private let center: CGPoint          // 滚轮事件落点（选区中心，屏幕坐标）
    private let stepPx: Int              // 每拍滚动像素
    private let interval: TimeInterval   // 每拍间隔（留页面滚动动画时间）
    private let maxTicks: Int
    private var ticks = 0
    private var timer: Timer?
    private var busy = false
    private var stopped = false
    var onTick: ((Int) -> Void)?         // 进度回调（拍数）

    init(session: ScrollCaptureSession, screen: NSScreen, region: CGRect,
         stepPx: Int = 110, interval: TimeInterval = 0.16, maxTicks: Int = 600) {
        self.session = session
        self.screen = screen
        self.region = region
        self.center = CGPoint(x: region.midX, y: region.midY)
        self.stepPx = stepPx
        self.interval = interval
        self.maxTicks = maxTicks
    }

    func start() {
        stopped = false
        tick()
    }

    func stop() {
        stopped = true
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard !stopped, !busy, ticks < maxTicks else {
            if ticks >= maxTicks { session.finishFromDriver() }
            return
        }
        busy = true
        let screen = self.screen
        let region = self.region
        Task { @MainActor in
            defer { busy = false }
            guard !stopped, !session.isTornDown else { return }
            do {
                let cg = try await Capture.grabRegion(screen: screen, regionPts: region)
                session.process(newFrame: ScrollCaptureSession.Frame(cg))
                ticks += 1
                onTick?(ticks)
                if session.isTornDown { stopped = true; return }   // 会话页尾自动完成/用户结束
                if ticks < maxTicks {
                    Self.postScrollWheel(at: center, pixels: -stepPx)
                    let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
                        self?.tick()
                    }
                    RunLoop.main.add(t, forMode: .common)
                    timer = t
                } else {
                    session.finishFromDriver()
                }
            } catch {
                if ticks < maxTicks {
                    let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
                        self?.tick()
                    }
                    RunLoop.main.add(t, forMode: .common)
                    timer = t
                }
            }
        }
    }

    /// 发送合成滚轮事件（落点 = 选区中心，正像素值向下滚）
    static func postScrollWheel(at point: CGPoint, pixels: Int) {
        guard let src = CGEventSource(stateID: .hidSystemState),
              let ev = CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 1,
                               wheel1: Int32(clamping: pixels), wheel2: 0, wheel3: 0) else { return }
        ev.location = point
        ev.post(tap: .cghidEventTap)
    }
}
