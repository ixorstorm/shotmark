import AppKit
import Vision

/// 文字识别（Vision：系统自带、离线、中英文）
enum OCR {

    /// 识别图中文字，返回按行拼接的文本；无文字/失败返回 nil。
    /// perform 是同步重活，扔后台队列跑，主线程只等结果。
    static func recognize(_ image: NSImage) async -> String? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["zh-Hans", "en-US"]
                request.usesLanguageCorrection = true
                let handler = VNImageRequestHandler(cgImage: cg, options: [:])
                do {
                    try handler.perform([request])
                    let results = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                    cont.resume(returning: results.isEmpty ? nil : results.joined(separator: "\n"))
                } catch {
                    cont.resume(returning: nil)
                }
            }
        }
    }
}
