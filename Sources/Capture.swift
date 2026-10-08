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
}
