// 全链路应用日志：启动/热键/抓屏/覆盖层/鼠标键盘/完成导出/复制/关闭
// 同步落盘（事件量小），避免崩溃时异步队列丢最后一拍。
import AppKit

enum AppLog {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/ShotMark", isDirectory: true)
    static let url = directory.appendingPathComponent("app.jsonl")
    private static let lock = NSLock()
    private static var launched = false

    static func launch() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        launched = true
        writeLocked("app_launch", [
            "pid": ProcessInfo.processInfo.processIdentifier,
            "executable": ProcessInfo.processInfo.arguments.first ?? "",
            "bundle": Bundle.main.bundlePath,
            "activationPolicy": NSApp.activationPolicy().rawValue,
            "args": ProcessInfo.processInfo.arguments.joined(separator: " "),
        ])
        fputs("[ShotMark] app log: \(url.path)\n", stderr)
    }

    /// 主线程上的完整现场；后台线程只传基本字段，不在这里读 AppKit。
    static func event(_ name: String, _ fields: [String: Any] = [:]) {
        var f = fields
        f["active"] = NSApp.isActive
        f["activationPolicy"] = NSApp.activationPolicy().rawValue
        f["frontmost"] = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        f["keyWindow"] = NSApp.keyWindow.map { "\(type(of: $0))#\($0.windowNumber)" } ?? "nil"
        f["mainWindow"] = NSApp.mainWindow.map { "\(type(of: $0))#\($0.windowNumber)" } ?? "nil"
        f["windowCount"] = NSApp.windows.count
        let m = NSEvent.mouseLocation
        f["mouse"] = "\(Int(m.x)),\(Int(m.y))"
        eventAnyThread(name, f)
    }

    static func eventAnyThread(_ name: String, _ fields: [String: Any] = [:]) {
        lock.lock(); defer { lock.unlock() }
        if !launched { try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        writeLocked(name, fields)
    }

    private static func writeLocked(_ name: String, _ fields: [String: Any]) {
        var obj: [String: Any] = ["t": Date().timeIntervalSince1970, "event": name]
        for (k, v) in fields { obj[k] = v }
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           (attrs[.size] as? Int ?? 0) > 4_000_000 {
            let old = directory.appendingPathComponent("app.previous.jsonl")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: url, to: old)
        }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(data); h.write(Data("\n".utf8)); try? h.close()
        } else {
            try? (data + Data("\n".utf8)).write(to: url)
        }
    }
}
