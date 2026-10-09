import AppKit
import Carbon.HIToolbox

/// 全局热键（Carbon RegisterEventHotKey：不需要辅助功能权限，也不要求 App 在前台）
/// 默认 ⌃⇧A。改键：改下面 keyCode / modifiers 两个常量后 `make` 重编。
enum HotKey {

    static var onFire: (() -> Void)?
    /// 临时会话键回调（滚动截屏期间截获空格/回车/Esc）。设置后 ⇧⌘A 回调暂停。
    static var onRawKey: ((UInt32) -> Void)?

    static func dispatch(keyCode: UInt32) {
        if let raw = onRawKey { raw(keyCode); return }
        onFire?()
    }

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

    /// 注册一组无修饰键的临时全局热键（滚动截屏会话用）。返回的 refs 传给 unregisterRaw。
    static func registerRaw(keys: [UInt32], action: @escaping (UInt32) -> Void) -> [EventHotKeyRef?] {
        onRawKey = action
        var refs: [EventHotKeyRef?] = []
        for (i, kc) in keys.enumerated() {
            var ref: EventHotKeyRef?
            let st = RegisterEventHotKey(kc, 0,
                                         EventHotKeyID(signature: fourCC("SMKS"), id: UInt32(i + 1)),
                                         GetApplicationEventTarget(), 0, &ref)
            if st == noErr { refs.append(ref) }
        }
        return refs
    }

    static func unregisterRaw(_ refs: [EventHotKeyRef?]) {
        for r in refs { if let r = r { UnregisterEventHotKey(r) } }
        onRawKey = nil
    }

    private static func fourCC(_ s: String) -> OSType {
        s.utf8.reduce(0) { ($0 << 8) + OSType($1) }
    }
}

/// Carbon 事件回调必须是顶层 C 约定函数（不能捕获上下文），读出 keyCode 经全局变量转发回主线程
private func hotkeyCallback(_: EventHandlerCallRef?, event: EventRef?, _: UnsafeMutableRawPointer?) -> OSStatus {
    var code: UInt32 = 0
    if let e = event {
        GetEventParameter(e, OSType(kEventParamKeyCode), OSType(typeUInt32), nil,
                          MemoryLayout<UInt32>.size, nil, &code)
    }
    DispatchQueue.main.async { HotKey.dispatch(keyCode: code) }
    return noErr
}
