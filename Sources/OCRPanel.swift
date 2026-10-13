import AppKit

/// 文字识别结果面板（飞书同款交互：先弹「识别中…」，结果可查看/编辑，用户点「复制文本」才进剪贴板）。
/// 手动 frame 布局（全项目无 AutoLayout），深色主题与工具栏一致。
final class OCRPanelController: NSObject {

    static let shared = OCRPanelController()

    private var panel: NSPanel?
    private var escMonitor: Any?
    private var textView: NSTextView?
    private var countField: NSTextField?
    private var copyButton: NSButton?

    /// ⚠️ borderless 窗默认 canBecomeKey = false（拿不到键盘焦点，文本框选不了）——子类打开
    private final class KeyablePanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    private let panelW: CGFloat = 460
    private let panelH: CGFloat = 340

    // MARK: - 对外接口

    func show(on screen: NSScreen) {
        if panel == nil { buildPanel() }
        guard let panel = panel else { return }
        panel.setFrame(NSRect(x: screen.frame.midX - panelW / 2,
                              y: screen.frame.midY - panelH / 2 + 40,
                              width: panelW, height: panelH), display: false)
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKey()
        if escMonitor == nil {
            escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                if e.keyCode == 53 { self?.close(); return nil }
                return e
            }
        }
    }

    func setLoading() {
        textView?.string = "识别中…"
        textView?.isEditable = false
        countField?.stringValue = ""
        setCopyEnabled(false)
    }

    func setResult(_ text: String) {
        textView?.isEditable = true
        if text.isEmpty {
            textView?.string = "未识别到文字"
            countField?.stringValue = ""
            setCopyEnabled(false)
            return
        }
        textView?.string = text
        let n = text.filter { !$0.isNewline }.count
        countField?.stringValue = "\(n) 字"
        setCopyEnabled(true)
        // 焦点给文本：⌘A / ⌘C 直接可用
        panel?.makeFirstResponder(textView)
    }

    func close() {
        panel?.orderOut(nil)
        if let m = escMonitor {
            NSEvent.removeMonitor(m)
            escMonitor = nil
        }
    }

    // MARK: - 动作

    @objc private func copyTapped() {
        guard let tv = textView, !tv.string.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(tv.string, forType: .string)
        setButton(copyButton, title: "已复制 ✓", bg: NSColor(srgbRed: 0.2, green: 0.6, blue: 0.3, alpha: 1))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self = self else { return }
            self.setButton(self.copyButton, title: "复制文本",
                           bg: NSColor(srgbRed: 0.13, green: 0.59, blue: 0.95, alpha: 1))
        }
    }

    @objc private func closeTapped() { close() }

    // MARK: - 构建

    private func buildPanel() {
        let panel = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: panelW, height: panelH),
                                 styleMask: .borderless, backing: .buffered, defer: false)
        // 覆盖层在 CGShieldingWindowLevel（~2024）——面板要压在它上面才能与截图状态共存（飞书同款）
        panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isReleasedWhenClosed = false   // ⚠️ 坑 #4：close() 自释放 + 属性 nil 化 = double free
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = true
        self.panel = panel

        let bg = NSView(frame: NSRect(x: 0, y: 0, width: panelW, height: panelH))
        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.97).cgColor
        bg.layer?.cornerRadius = 12

        // 标题 + 字数
        let title = NSTextField(labelWithString: "文字识别")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .white
        title.frame = NSRect(x: 16, y: panelH - 30, width: 90, height: 18)
        bg.addSubview(title)

        let count = NSTextField(labelWithString: "")
        count.font = .systemFont(ofSize: 11)
        count.textColor = NSColor.white.withAlphaComponent(0.55)
        count.frame = NSRect(x: 106, y: panelH - 28, width: 120, height: 16)
        bg.addSubview(count)
        countField = count

        // ✕
        let closeBtn = smallBtn("✕", fg: NSColor.white.withAlphaComponent(0.7))
        closeBtn.target = self
        closeBtn.action = #selector(closeTapped)
        closeBtn.frame = NSRect(x: panelW - 36, y: panelH - 32, width: 26, height: 22)
        bg.addSubview(closeBtn)

        // 文本区
        let tv = NSTextView()
        tv.isRichText = false
        tv.font = .systemFont(ofSize: 12.5)
        tv.textColor = .white
        tv.drawsBackground = false
        tv.insertionPointColor = .white
        tv.isAutomaticQuoteSubstitutionEnabled = false   // 别自作聪明改字符
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.textContainer?.lineFragmentPadding = 8

        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.frame = NSRect(x: 12, y: 54, width: panelW - 24, height: panelH - 54 - 46)
        scroll.drawsBackground = false   // ⚠️ 默认 true 自带白底，会盖住深色 layer（白底白字事故）
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.wantsLayer = true
        scroll.layer?.backgroundColor = NSColor(white: 0.08, alpha: 1).cgColor
        scroll.layer?.cornerRadius = 8
        scroll.layer?.masksToBounds = true
        bg.addSubview(scroll)
        textView = tv

        // 底部按钮
        let copy = NSButton(title: "复制文本", target: self, action: #selector(copyTapped))
        setButton(copy, title: "复制文本", bg: NSColor(srgbRed: 0.13, green: 0.59, blue: 0.95, alpha: 1))
        copy.frame = NSRect(x: panelW - 12 - 96, y: 13, width: 96, height: 28)
        bg.addSubview(copy)
        copyButton = copy

        let close2 = NSButton(title: "关闭", target: self, action: #selector(closeTapped))
        setButton(close2, title: "关闭", bg: NSColor(white: 0.22, alpha: 1))
        close2.frame = NSRect(x: panelW - 12 - 96 - 8 - 68, y: 13, width: 68, height: 28)
        bg.addSubview(close2)

        panel.contentView = bg
    }

    private func setCopyEnabled(_ on: Bool) {
        copyButton?.isEnabled = on
        copyButton?.layer?.backgroundColor = (on
            ? NSColor(srgbRed: 0.13, green: 0.59, blue: 0.95, alpha: 1)
            : NSColor(white: 0.22, alpha: 1)).cgColor
    }

    /// 无边框药丸按钮（深色主题：attr title 白字 + layer 底色）
    private func setButton(_ b: NSButton?, title: String, bg: NSColor) {
        guard let b = b else { return }
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.backgroundColor = bg.cgColor
        b.layer?.cornerRadius = 6
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ])
    }

    private func smallBtn(_ t: String, fg: NSColor) -> NSButton {
        let b = NSButton(title: t, target: nil, action: nil)
        b.isBordered = false
        b.attributedTitle = NSAttributedString(string: t, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: fg,
        ])
        return b
    }
}
