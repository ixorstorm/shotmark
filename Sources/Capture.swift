import AppKit
import ScreenCaptureKit
import CoreGraphics

enum CaptureError: Error {
    case noDisplayID
    case displayNotFound
}

/// 屏幕捕获（ScreenCaptureKit，macOS 14+ 的 SCScreenshotManager 同步语义异步 API）
enum Capture {

    // MARK: - 内容清单缓存（SCShareableContent 单次 ~55ms，滚动会话 70-150ms/拍每次重拉是浪费）

    private static var contentCache: (content: SCShareableContent, at: Date)?
    private static var contentTask: Task<SCShareableContent, Error>?

    /// 5s 内的清单直接用缓存；并发调用共享同一个拉取任务
    static func content() async throws -> SCShareableContent {
        if let c = contentCache, Date().timeIntervalSince(c.at) < 5 { return c.content }
        if let t = contentTask { return try await t.value }
        let t = Task { try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) }
        contentTask = t
        do {
            let c = try await t.value
            contentCache = (c, Date())
            contentTask = nil
            return c
        } catch {
            contentTask = nil
            throw error
        }
    }

    /// App 启动后后台预热 SCK/TCC 管线，让第一次按热键就命中缓存
    static func warm() {
        Task { _ = try? await content() }
    }

    /// 绕过缓存拉新鲜清单（显示器过渡期/兜底重试用）
    static func freshContent() async throws -> SCShareableContent {
        let c = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        contentCache = (c, Date())
        return c
    }

    static func invalidateContentCache() { contentCache = nil }

    static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    /// 找 SCDisplay：displayID 优先，失配（显示器切换过渡期实测会发生）按分辨率几何兜底
    static func findDisplay(for screen: NSScreen, in content: SCShareableContent) -> SCDisplay? {
        if let id = displayID(for: screen),
           let d = content.displays.first(where: { $0.displayID == id }) {
            return d
        }
        let w = Int(screen.frame.width), h = Int(screen.frame.height)
        return content.displays.first(where: { $0.width == w && $0.height == h })
    }

    static func grab(screen: NSScreen) async throws -> CGImage {
        let t0 = Date()
        let content = try await freshContent()   // 热键路径不用缓存：过渡期缓存清单里的 SCDisplay 会失配
        let t1 = Date()
        fputs("[timing] ShareableContent \(String(format: "%.0f", t1.timeIntervalSince(t0)*1000))ms\n", stderr)
        guard let display = findDisplay(for: screen, in: content) else {
            throw CaptureError.displayNotFound
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        config.width = Int(filter.contentRect.width * scale)
        config.height = Int(filter.contentRect.height * scale)
        config.showsCursor = false
        let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        fputs("[timing] captureImage \(String(format: "%.0f", Date().timeIntervalSince(t1)*1000))ms\n", stderr)
        return img
    }

    /// 只抓某块区域（滚动截屏用）。regionPts 为屏内点坐标（AppKit y-up，原点左下）。
    static func grabRegion(screen: NSScreen, regionPts: CGRect) async throws -> CGImage {
        var content = try await content()
        var display = findDisplay(for: screen, in: content)
        if display == nil {
            invalidateContentCache()
            content = try await freshContent()
            display = findDisplay(for: screen, in: content)
        }
        guard let display else { throw CaptureError.displayNotFound }
        // 排除本进程自己的窗口（边框提示窗/实时预览窗），防止被拼进长图
        let ourPID = ProcessInfo.processInfo.processIdentifier
        let excluded = content.windows.filter { $0.owningApplication?.processID == ourPID }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)
        let scale = CGFloat(filter.pointPixelScale)
        // SCK 的 sourceRect 原点为左上（y 向下），需从 AppKit y-up 转换
        let src = CGRect(x: regionPts.minX,
                         y: screen.frame.height - regionPts.maxY,
                         width: regionPts.width,
                         height: regionPts.height)
        let config = SCStreamConfiguration()
        config.sourceRect = src
        config.width = Int(regionPts.width * scale)
        config.height = Int(regionPts.height * scale)
        config.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}
