import AppKit
import Carbon.HIToolbox

/// 全局热键（Carbon RegisterEventHotKey：不需要辅助功能权限，也不要求 App 在前台）
/// 默认 ⌃⇧A。改键：改下面 HOTKEY_* 两个常量后 `make` 重编。
enum HotKey {

    static var onFire: (() -> Void)?

    static func register() -> Bool {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotkeyCallback, 1, &spec, nil, nil)

        let keyCode = UInt32(kVK_ANSI_A)
        let modifiers = UInt32(controlKey | shiftKey)
        let hotKeyID = EventHotKeyID(signature: fourCC("SMK1"), id: 1)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status != noErr {
            fputs("[ShotMark] 热键注册失败（status=\(status)），可能被其他 App 占用\n", stderr)
            return false
        }
        return true
    }

    private static func fourCC(_ s: String) -> OSType {
        s.utf8.reduce(0) { ($0 << 8) + OSType($1) }
    }
}

/// Carbon 事件回调必须是顶层 C 约定函数（不能捕获上下文），经全局变量转发回主线程
private func hotkeyCallback(_: EventHandlerCallRef?, _: EventRef?, _: UnsafeMutableRawPointer?) -> OSStatus {
    DispatchQueue.main.async { HotKey.onFire?() }
    return noErr
}
