import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // 无 Dock 图标，常驻后台
let delegate = AppDelegate()
app.delegate = delegate
app.run()
