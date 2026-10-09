import AppKit
import ScreenCaptureKit
import CoreGraphics

enum CaptureError: Error {
    case noDisplayID
    case displayNotFound
}

/// 屏幕捕获（ScreenCaptureKit，macOS 14+ 的 SCScreenshotManager 同步语义异步 API）
enum Capture {

    static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    static func grab(screen: NSScreen) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let id = displayID(for: screen) else { throw CaptureError.noDisplayID }
        guard let display = content.displays.first(where: { $0.displayID == id }) else {
            throw CaptureError.displayNotFound
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        config.width = Int(filter.contentRect.width * scale)
        config.height = Int(filter.contentRect.height * scale)
        config.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// 只抓某块区域（滚动截屏用）。regionPts 为屏内点坐标（AppKit y-up，原点左下）。
    static func grabRegion(screen: NSScreen, regionPts: CGRect) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let id = displayID(for: screen) else { throw CaptureError.noDisplayID }
        guard let display = content.displays.first(where: { $0.displayID == id }) else {
            throw CaptureError.displayNotFound
        }
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
