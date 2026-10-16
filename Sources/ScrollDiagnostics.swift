// 滚动截屏会话级全量诊断：事件 JSONL + 帧图/拼接图落盘（后台队列写盘，不阻塞滚动）
import AppKit
import CoreGraphics
import ImageIO

final class ScrollDiagnostics {
    let dir: URL
    let logURL: URL
    private let queue = DispatchQueue(label: "shotmark.diagnostics", qos: .utility)
    private var tickNo = 0
    private var savedRoutine = 0

    init(region: CGRect) {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shotmark-debug")
            .appendingPathComponent(f.string(from: Date()))
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        logURL = dir.appendingPathComponent("scroll.jsonl")
        event("session_start", [
            "region": "\(Int(region.origin.x)),\(Int(region.origin.y)),\(Int(region.width))x\(Int(region.height))"
        ])
        fputs("[ShotMark] diagnostics dir: \(dir.path)\n", stderr)
    }

    func event(_ name: String, _ fields: [String: String] = [:]) {
        queue.async {
            var obj: [String: Any] = ["t": Date().timeIntervalSince1970, "event": name]
            for (k, v) in fields { obj[k] = v }
            guard let data = try? JSONSerialization.data(withJSONObject: obj),
                  let line = String(data: data + Data("\n".utf8), encoding: .utf8) else { return }
            self.append(line, to: self.logURL)
        }
    }

    /// 常规帧：每 8 拍留一张 JPEG（轻量）；异常帧/重锚定/验伪帧：全 PNG
    func saveRoutineIfDue(_ cg: CGImage) {
        tickNo += 1
        guard tickNo % 8 == 0 else { return }
        save(cg, name: "frame-\(tickNo)-routine", jpeg: true)
    }

    func saveAnomaly(_ cg: CGImage, tag: String) {
        save(cg, name: "frame-\(tickNo)-\(tag)", jpeg: false)
    }

    func saveComposite(_ img: NSImage?, tag: String = "finish") {
        guard let cg = img?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        save(cg, name: tag, jpeg: false)
    }

    private func save(_ cg: CGImage, name: String, jpeg: Bool) {
        queue.async {
            let ext = jpeg ? "jpg" : "png"
            let url = self.dir.appendingPathComponent(name + "." + ext)
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL,
                jpeg ? "public.jpeg" as CFString : "public.png" as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(dest, cg, nil)
            CGImageDestinationFinalize(dest)
            if jpeg {
                self.savedRoutine += 1
                // 只保留最近 160 张常规帧，异常/结果图不删
                if self.savedRoutine > 160 {
                    let old = self.dir.appendingPathComponent("frame-\(self.tickNo - 160 * 8)-routine.jpg")
                    try? FileManager.default.removeItem(at: old)
                }
            }
        }
    }

    private func append(_ line: String, to url: URL) {
        guard let data = line.data(using: .utf8) else { return }
        if let fh = FileHandle(forWritingAtPath: url.path) {
            fh.seekToEndOfFile(); fh.write(data); try? fh.close()
        } else {
            try? data.write(to: url)
        }
    }
}
