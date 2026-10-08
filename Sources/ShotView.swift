import AppKit

enum FinishAction { case copy, save, pin }

protocol ShotViewDelegate: AnyObject {
    /// image=nil 表示取消
    func shotView(_ view: ShotView, didFinish image: NSImage?, action: FinishAction?)
}

/// 截图标注主视图：全屏覆盖，承载选区、标注、工具栏。
/// 坐标系：AppKit 默认（y 轴向上）。
final class ShotView: NSView {

    let captured: NSImage
    weak var delegate: ShotViewDelegate?

    var selection: CGRect?
    var annotations: [Annotation] = []
    var pending: Annotation?
    var tool: Tool?                       // nil = 选区/移动模式
    var colorIndex = 0                    // 默认红
    var widthIndex = 1
    static let widths: [CGFloat] = [2.5, 4, 7]
    var lineWidth: CGFloat { ShotView.widths[widthIndex] }
    var color: NSColor { Model.palette[colorIndex] }

    private enum Drag {
        case none
        case creating(CGPoint)            // 拖选区
        case moving(CGPoint)              // offset = 点击点 - 选区 origin
        case resizing(Int, CGRect)        // handle 序号 + 原始 rect
        case drawing                      // 正在画标注
    }
    private var drag: Drag = .none

    private var textField: NSTextField?
    private var textAnchor: CGPoint = .zero

    private var trackingAreaRef: NSTrackingArea?

    // MARK: - 初始化

    init(frame f: NSRect, captured: NSImage) {
        self.captured = captured
        super.init(frame: f)
    }
    required init?(coder: NSCoder) { fatalError("not supported") }

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        captured.draw(in: bounds)

        // 暗色蒙层 + 选区镂空
        let dim = NSBezierPath(rect: bounds)
        if let sel = selection { dim.append(NSBezierPath(rect: sel)) }
        dim.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.45).setFill()
        dim.fill()

        guard let sel = selection, sel.width >= 2, sel.height >= 2 else {
            drawHint()
            return
        }

        // 标注（裁剪在选区内）
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: sel).addClip()
        for a in annotations { Render.draw(annotation: a, mosaicSource: captured) }
        if let p = pending { Render.draw(annotation: p, mosaicSource: captured) }
        NSGraphicsContext.restoreGraphicsState()

        // 选区边框 + 尺寸标签 + 手柄 + 工具栏
        NSColor(srgbRed: 0.13, green: 0.59, blue: 0.95, alpha: 1).setStroke()
        let border = NSBezierPath(rect: sel)
        border.lineWidth = 1
        border.stroke()
        drawSizeLabel(sel)
        drawHandles(sel)
        drawToolbar(sel)
    }

    private func drawHint() {
        let text = "拖拽选择截图区域    ·    Esc 退出"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.9),
        ]
        let s = NSString(string: text).size(withAttributes: attrs)
        let pt = CGPoint(x: bounds.midX - s.width / 2, y: bounds.midY - s.height / 2)
        NSString(string: text).draw(at: pt, withAttributes: attrs)
    }

    private func drawSizeLabel(_ sel: CGRect) {
        let text = "\(Int(sel.width)) × \(Int(sel.height))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.white,
        ]
        let s = NSString(string: text).size(withAttributes: attrs)
        let pad: CGFloat = 5
        var ly = sel.maxY + 6
        if ly + s.height + pad * 2 > bounds.height { ly = sel.maxY - s.height - pad * 2 - 6 }
        let bg = NSRect(x: sel.minX, y: ly, width: s.width + pad * 2, height: s.height + pad * 2)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: bg, xRadius: 4, yRadius: 4).fill()
        NSString(string: text).draw(at: CGPoint(x: bg.minX + pad, y: bg.minY + pad - 1), withAttributes: attrs)
    }

    // MARK: - 手柄

    /// 顺序：左下、下中、右下、右中、右上、上中、左上、左中（y 向上）
    private func handleRects(_ sel: CGRect) -> [CGRect] {
        let s: CGFloat = 8, h = s / 2
        let pts = [
            CGPoint(x: sel.minX, y: sel.minY), CGPoint(x: sel.midX, y: sel.minY),
            CGPoint(x: sel.maxX, y: sel.minY), CGPoint(x: sel.maxX, y: sel.midY),
            CGPoint(x: sel.maxX, y: sel.maxY), CGPoint(x: sel.midX, y: sel.maxY),
            CGPoint(x: sel.minX, y: sel.maxY), CGPoint(x: sel.minX, y: sel.midY),
        ]
        return pts.map { CGRect(x: $0.x - h, y: $0.y - h, width: s, height: s) }
    }

    private func handleIndex(at p: CGPoint, sel: CGRect) -> Int? {
        for (i, r) in handleRects(sel).enumerated() where r.insetBy(dx: -3, dy: -3).contains(p) { return i }
        return nil
    }

    private func drawHandles(_ sel: CGRect) {
        for r in handleRects(sel) {
            NSColor.white.setFill()
            NSBezierPath(rect: r).fill()
            NSColor(srgbRed: 0.13, green: 0.59, blue: 0.95, alpha: 1).setStroke()
            let p = NSBezierPath(rect: r)
            p.lineWidth = 1
            p.stroke()
        }
    }

    private func resizeRect(handle i: Int, orig r: CGRect, to p: CGPoint) -> CGRect {
        var x1 = r.minX, x2 = r.maxX, y1 = r.minY, y2 = r.maxY
        if [2, 3, 4].contains(i) { x2 = p.x }   // 东侧移动
        if [0, 6, 7].contains(i) { x1 = p.x }   // 西侧
        if [4, 5, 6].contains(i) { y2 = p.y }   // 北侧
        if [0, 1, 2].contains(i) { y1 = p.y }   // 南侧
        var nr = CGRect(x: min(x1, x2), y: min(y1, y2),
                        width: max(4, abs(x2 - x1)), height: max(4, abs(y2 - y1)))
        nr = nr.intersection(bounds)
        return nr.isNull ? r : nr
    }

    // MARK: - 工具栏

    private enum Btn { case tool(Tool), color(Int), width, undo, pin, save, copy, cancel }

    private let toolOrder: [(Tool, String)] = [
        (.pen, "pencil"), (.arrow, "arrow.up.right"), (.rect, "rectangle"),
        (.ellipse, "circle"), (.text, "textformat"), (.mosaic, "square.grid.3x3"),
    ]

    private func toolbarLayout(_ sel: CGRect) -> (strip: CGRect, items: [(Btn, CGRect)]) {
        var items: [(Btn, CGRect)] = []
        var x: CGFloat = 10
        let h: CGFloat = 36
        func push(_ b: Btn, _ w: CGFloat) {
            items.append((b, CGRect(x: x, y: (h - 28) / 2, width: w, height: 28)))
            x += w
        }
        for (t, _) in toolOrder { push(.tool(t), 30) }
        x += 10
        for i in 0..<Model.palette.count { push(.color(i), 21) }
        x += 10
        push(.width, 34)
        x += 10
        for b in [Btn.undo, .pin, .save, .copy, .cancel] { push(b, 30) }
        x += 10
        let stripW = x

        var sx = sel.maxX - stripW
        sx = min(max(8, sx), max(8, bounds.width - stripW - 8))
        var sy = sel.minY - h - 8
        if sy < 8 { sy = sel.maxY + 8 }
        if sy + h > bounds.height - 8 { sy = bounds.height - h - 8 }
        let strip = CGRect(x: sx, y: sy, width: stripW, height: h)
        return (strip, items.map { ($0.0, $0.1.offsetBy(dx: sx, dy: sy)) })
    }

    private func drawToolbar(_ sel: CGRect) {
        let (strip, items) = toolbarLayout(sel)
        NSColor(white: 0.13, alpha: 0.96).setFill()
        NSBezierPath(roundedRect: strip, xRadius: 8, yRadius: 8).fill()
        NSColor.white.withAlphaComponent(0.15).setStroke()
        let sp = NSBezierPath(roundedRect: strip, xRadius: 8, yRadius: 8)
        sp.lineWidth = 0.5
        sp.stroke()

        for (btn, r) in items {
            switch btn {
            case .tool(let t):
                if tool == t {
                    NSColor.white.withAlphaComponent(0.22).setFill()
                    NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
                }
                let name = toolOrder.first { $0.0 == t }!.1
                drawIcon(name, in: r, tint: .white)
            case .color(let i):
                let d: CGFloat = 13
                let cr = CGRect(x: r.midX - d / 2, y: r.midY - d / 2, width: d, height: d)
                Model.palette[i].setFill()
                NSBezierPath(ovalIn: cr).fill()
                if colorIndex == i {
                    NSColor.white.setStroke()
                    let ring = NSBezierPath(ovalIn: cr.insetBy(dx: -2.5, dy: -2.5))
                    ring.lineWidth = 1.5
                    ring.stroke()
                }
            case .width:
                // 画一条当前颜色 + 当前线宽的预览线
                color.setStroke()
                let path = NSBezierPath()
                path.lineWidth = lineWidth
                path.lineCapStyle = .round
                path.move(to: CGPoint(x: r.minX + 6, y: r.midY))
                path.line(to: CGPoint(x: r.maxX - 6, y: r.midY))
                path.stroke()
            case .undo:
                drawIcon("arrow.uturn.left", in: r, tint: .white, alpha: annotations.isEmpty ? 0.3 : 1)
            case .pin:
                drawIcon("pin.fill", in: r, tint: .white)
            case .save:
                drawIcon("square.and.arrow.down", in: r, tint: .white)
            case .copy:
                drawIcon("checkmark", in: r, tint: NSColor(srgbRed: 0.3, green: 0.85, blue: 0.4, alpha: 1))
            case .cancel:
                drawIcon("xmark", in: r, tint: NSColor(srgbRed: 1, green: 0.4, blue: 0.38, alpha: 1))
            }
        }
    }

    private func drawIcon(_ name: String, in r: CGRect, tint: NSColor, alpha: CGFloat = 1) {
        let img = Render.symbolImage(name, size: 14, tint: tint)
        let rect = CGRect(x: r.midX - img.size.width / 2, y: r.midY - img.size.height / 2,
                          width: img.size.width, height: img.size.height)
        img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: alpha)
    }

    // MARK: - 鼠标事件

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        let p = event.locationInWindow
        commitText()

        if let sel = selection {
            let (strip, items) = toolbarLayout(sel)
            if strip.contains(p) {
                if let (btn, _) = items.first(where: { $0.1.contains(p) }) { handleButton(btn) }
                needsDisplay = true
                return
            }
            if let h = handleIndex(at: p, sel: sel) {
                drag = .resizing(h, sel)
                return
            }
            if sel.contains(p) {
                if tool == .text { startText(at: p); return }
                if let t = tool {
                    var a = Annotation(tool: t, color: color, width: lineWidth)
                    a.points = [p]
                    a.p1 = p
                    a.p2 = p
                    pending = a
                    drag = .drawing
                } else {
                    drag = .moving(CGPoint(x: p.x - sel.minX, y: p.y - sel.minY))
                }
                return
            }
        }
        // 空白处按下 = 重新选区
        drag = .creating(p)
        selection = CGRect(origin: p, size: .zero)
        pending = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = clampToBounds(event.locationInWindow)
        switch drag {
        case .creating(let o):
            selection = CGRect(p1: o, p2: p)
        case .moving(let off):
            guard var nr = selection else { break }
            nr.origin = CGPoint(x: p.x - off.x, y: p.y - off.y)
            nr.origin = CGPoint(
                x: min(max(0, nr.origin.x), max(0, bounds.width - nr.width)),
                y: min(max(0, nr.origin.y), max(0, bounds.height - nr.height)))
            selection = nr
        case .resizing(let h, let orig):
            selection = resizeRect(handle: h, orig: orig, to: p)
        case .drawing:
            if pending?.tool == .pen { pending?.points.append(p) } else { pending?.p2 = p }
        case .none:
            break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        switch drag {
        case .creating:
            if let sel = selection, (sel.width < 3 || sel.height < 3) { selection = nil }
        case .drawing:
            if let pd = pending {
                if pd.tool == .pen {
                    if pd.points.count > 1 { annotations.append(pd) }
                } else {
                    let r = CGRect(p1: pd.p1, p2: pd.p2)
                    if r.width >= 3 || r.height >= 3 { annotations.append(pd) }
                }
            }
            pending = nil
        default:
            break
        }
        drag = .none
        needsDisplay = true
    }

    private func clampToBounds(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(0, p.x), bounds.width), y: min(max(0, p.y), bounds.height))
    }

    // MARK: - 工具栏动作

    private func handleButton(_ btn: Btn) {
        switch btn {
        case .tool(let t):
            tool = (tool == t) ? nil : t
            window?.invalidateCursorRects(for: self)
        case .color(let i):
            colorIndex = i
        case .width:
            widthIndex = (widthIndex + 1) % ShotView.widths.count
        case .undo:
            if !annotations.isEmpty { annotations.removeLast() }
        case .copy:
            finish(.copy)
            return
        case .save:
            finish(.save)
            return
        case .pin:
            finish(.pin)
            return
        case .cancel:
            delegate?.shotView(self, didFinish: nil, action: nil)
            return
        }
        needsDisplay = true
    }

    private func finish(_ action: FinishAction) {
        guard let sel = selection,
              let img = Render.export(captured: captured, selection: sel, annotations: annotations) else {
            delegate?.shotView(self, didFinish: nil, action: nil)
            return
        }
        delegate?.shotView(self, didFinish: img, action: action)
    }

    // MARK: - 键盘

    override func keyDown(with event: NSEvent) {
        if textField != nil { super.keyDown(with: event); return }
        let cmd = event.modifierFlags.contains(.command)
        switch event.keyCode {
        case 53:  // Esc
            delegate?.shotView(self, didFinish: nil, action: nil)
        case 36:  // Return = 复制
            finish(.copy)
        case 6 where cmd:  // ⌘Z
            if !annotations.isEmpty { annotations.removeLast(); needsDisplay = true }
        case 8 where cmd:  // ⌘C
            finish(.copy)
        case 1 where cmd:  // ⌘S
            finish(.save)
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - 文字标注

    private func startText(at p: CGPoint) {
        let tf = NSTextField(frame: NSRect(x: p.x, y: p.y - 13, width: 280, height: 28))
        tf.font = NSFont.systemFont(ofSize: 14 + lineWidth * 2, weight: .medium)
        tf.textColor = color
        tf.isBordered = false
        tf.drawsBackground = true
        tf.backgroundColor = NSColor.black.withAlphaComponent(0.35)
        tf.focusRingType = .none
        tf.placeholderString = "输入文字，回车确认"
        tf.target = self
        tf.action = #selector(commitTextAction(_:))
        addSubview(tf)
        NotificationCenter.default.addObserver(self, selector: #selector(commitTextAction(_:)),
                                               name: NSControl.textDidEndEditingNotification, object: tf)
        textField = tf
        textAnchor = p
        window?.makeFirstResponder(tf)
    }

    private func commitText() { commitTextAction(nil) }

    @objc private func commitTextAction(_ sender: Any?) {
        guard let tf = textField else { return }
        let s = tf.stringValue
        if !s.isEmpty {
            var a = Annotation(tool: .text, color: tf.textColor ?? color, width: lineWidth)
            a.p1 = textAnchor
            a.text = s
            annotations.append(a)
        }
        NotificationCenter.default.removeObserver(self, name: NSControl.textDidEndEditingNotification, object: tf)
        tf.removeFromSuperview()
        textField = nil
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    // MARK: - 光标

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingAreaRef { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingAreaRef = t
    }

    override func mouseMoved(with event: NSEvent) {
        let p = event.locationInWindow
        if let sel = selection {
            let (strip, _) = toolbarLayout(sel)
            if strip.contains(p) { NSCursor.pointingHand.set(); return }
            if sel.contains(p) { (tool == .text ? NSCursor.iBeam : NSCursor.crosshair).set(); return }
        }
        NSCursor.crosshair.set()
    }
}
