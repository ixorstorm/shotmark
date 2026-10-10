import AppKit

/// 标注工具
enum Tool: String {
    case pen, arrow, rect, ellipse, text, mosaic
}

/// 一条标注（坐标一律为视图点坐标，y 轴向上，与 AppKit 默认一致）
struct Annotation {
    var tool: Tool
    var color: NSColor
    var width: CGFloat
    var points: [CGPoint]   // pen 轨迹
    var p1: CGPoint         // 形状起点 / text 锚点
    var p2: CGPoint         // 形状终点
    var text: String
    var scale: CGFloat      // text 字号缩放（拖角调）

    init(tool: Tool, color: NSColor, width: CGFloat) {
        self.tool = tool
        self.color = color
        self.width = width
        self.points = []
        self.p1 = .zero
        self.p2 = .zero
        self.text = ""
        self.scale = 1
    }
}

extension Annotation {
    /// 文字字号（渲染公式与 Render.draw 保持一致）
    var fontSize: CGFloat { (14 + width * 2) * scale }

    /// 包围盒（命中测试/虚线框/手柄用）
    var bounds: CGRect {
        switch tool {
        case .text:
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
            ]
            let ts = NSString(string: text).size(withAttributes: attrs)
            return CGRect(x: p1.x, y: p1.y, width: ts.width, height: ts.height)
        case .pen:
            guard let first = points.first else { return .zero }
            var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
            for pt in points {
                minX = min(minX, pt.x); minY = min(minY, pt.y)
                maxX = max(maxX, pt.x); maxY = max(maxY, pt.y)
            }
            return CGRect(x: minX, y: minY, width: max(1, maxX - minX), height: max(1, maxY - minY))
        case .arrow, .rect, .ellipse, .mosaic:
            return CGRect(p1: p1, p2: p2)
        }
    }

    func translated(by d: CGPoint) -> Annotation {
        var a = self
        a.p1 = CGPoint(x: p1.x + d.x, y: p1.y + d.y)
        a.p2 = CGPoint(x: p2.x + d.x, y: p2.y + d.y)
        a.points = points.map { CGPoint(x: $0.x + d.x, y: $0.y + d.y) }
        return a
    }

    /// 拖角缩放。handle: 0=左下 1=右下 2=右上 3=左上（y-up）；orig = 原始包围盒
    func resized(handle: Int, from orig: CGRect, to p: CGPoint) -> Annotation {
        var a = self
        let anchor = CGPoint(x: (handle == 0 || handle == 3) ? orig.maxX : orig.minX,
                             y: (handle == 0 || handle == 1) ? orig.maxY : orig.minY)
        switch tool {
        case .text:
            // 文字按宽度比例缩放字号（飞书同款手感）
            let ow = max(orig.width, 1)
            let nw = abs(p.x - anchor.x)
            a.scale = min(6, max(0.3, scale * nw / ow))
        case .arrow:
            // 拖动哪侧手柄就动哪个端点
            if handle == 0 || handle == 3 { a.p1 = p } else { a.p2 = p }
        default:
            let nr = CGRect(p1: anchor, p2: p)
            let sx = nr.width / max(orig.width, 1)
            let sy = nr.height / max(orig.height, 1)
            if tool == .pen {
                a.points = points.map { pt in
                    CGPoint(x: nr.minX + (pt.x - orig.minX) * sx,
                            y: nr.minY + (pt.y - orig.minY) * sy)
                }
            } else {
                a.p1 = nr.origin
                a.p2 = CGPoint(x: nr.maxX, y: nr.maxY)
            }
        }
        return a
    }
}

/// 全局配色板（对标飞书：红/橙/黄/绿/蓝/白/黑）
enum Model {
    static let palette: [NSColor] = [
        NSColor(srgbRed: 1.00, green: 0.23, blue: 0.19, alpha: 1),  // 红（默认）
        NSColor(srgbRed: 1.00, green: 0.58, blue: 0.00, alpha: 1),  // 橙
        NSColor(srgbRed: 1.00, green: 0.80, blue: 0.00, alpha: 1),  // 黄
        NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1),  // 绿
        NSColor(srgbRed: 0.04, green: 0.52, blue: 1.00, alpha: 1),  // 蓝
        NSColor.white,
        NSColor.black,
    ]
}

extension CGRect {
    /// 由任意两角点构造标准矩形
    init(p1: CGPoint, p2: CGPoint) {
        self.init(x: min(p1.x, p2.x), y: min(p1.y, p2.y),
                  width: abs(p2.x - p1.x), height: abs(p2.y - p1.y))
    }
}
