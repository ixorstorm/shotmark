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

    init(tool: Tool, color: NSColor, width: CGFloat) {
        self.tool = tool
        self.color = color
        self.width = width
        self.points = []
        self.p1 = .zero
        self.p2 = .zero
        self.text = ""
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
