import Carbon.HIToolbox
import Foundation
import os

/// 快捷键组合（Carbon 键码 + Carbon 修饰键掩码）。持久化与自定义 UI 在 Phase 11 接入。
struct HotKeyCombo: Equatable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32

    /// 默认：⌘⇧V（§26）。
    static let defaultOpenClipboard = HotKeyCombo(
        keyCode: UInt32(kVK_ANSI_V),
        modifiers: UInt32(cmdKey | shiftKey)
    )

    /// 从 UserDefaults 读取用户自定义组合；未设置时返回默认 ⌘⇧V。
    static var stored: HotKeyCombo {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "hotKeyCode") != nil,
              let code = (defaults.object(forKey: "hotKeyCode") as? NSNumber)?.intValue,
              let mods = (defaults.object(forKey: "hotKeyModifiers") as? NSNumber)?.intValue
        else {
            return .defaultOpenClipboard
        }
        return HotKeyCombo(keyCode: UInt32(code), modifiers: UInt32(mods))
    }

    static func save(_ combo: HotKeyCombo) {
        UserDefaults.standard.set(Int(combo.keyCode), forKey: "hotKeyCode")
        UserDefaults.standard.set(Int(combo.modifiers), forKey: "hotKeyModifiers")
    }

    static func resetToDefault() {
        UserDefaults.standard.removeObject(forKey: "hotKeyCode")
        UserDefaults.standard.removeObject(forKey: "hotKeyModifiers")
    }

    /// 设置页展示用（§49）。
    var displayString: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        text += keyCharacter
        return text
    }

    private var keyCharacter: String {
        // 常用键码的可读名称；其余键显示 unicode 字符
        let namedKeys: [UInt32: String] = [
            UInt32(kVK_Space): "Space",
            UInt32(kVK_Return): "↩",
            UInt32(kVK_Tab): "⇥",
            UInt32(kVK_Escape): "⎋",
            UInt32(kVK_ForwardDelete): "⌦",
            UInt32(kVK_LeftArrow): "←",
            UInt32(kVK_RightArrow): "→",
            UInt32(kVK_DownArrow): "↓",
            UInt32(kVK_UpArrow): "↑",
        ]
        if let named = namedKeys[keyCode] {
            return named
        }
        // Carbon ANSI 键码 → 字符（注意：键码顺序不等于键盘表面顺序）
        let ansiCharacters: [UInt32: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
            11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
            18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9",
            26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
            36: "↩", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 49: "Space",
        ]
        return ansiCharacters[keyCode] ?? String(format: "Key(%d)", keyCode)
    }
}

/// 快捷键注册失败（§53）。
enum GlobalShortcutError: LocalizedError {
    case installHandlerFailed(OSStatus)
    case registerFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .installHandlerFailed(let status): "快捷键事件处理器安装失败（\(status)）。"
        case .registerFailed(let status):
            status == Int(eventHotKeyExistsErr)
                ? "该快捷键已被其他应用占用，请更换组合。"
                : "快捷键注册失败（\(status)）。"
        }
    }
}

/// 全局快捷键管理（§26）。基于 Carbon RegisterEventHotKey —— macOS 全局热键的标准机制。
/// 所有方法仅在主线程调用。
@MainActor
final class GlobalShortcutManager {
    static let shared = GlobalShortcutManager()

    private let logger = Logger(subsystem: "com.paste.app", category: "shortcut")

    private var eventHandlerRef: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?
    private var contextBox: HotKeyContextBox?
    private(set) var currentCombo: HotKeyCombo?

    private init() {}

    /// 注册全局快捷键；重复注册会先注销旧的。
    func register(_ combo: HotKeyCombo, handler: @escaping () -> Void) throws {
        unregister()

        // 事件类型与回调只装一次；换键只需重新 RegisterEventHotKey
        if eventHandlerRef == nil {
            var eventType = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            )
            let box = HotKeyContextBox(handler: handler)
            let userData = Unmanaged.passRetained(box)
            let status = InstallEventHandler(
                GetApplicationEventTarget(),
                carbonEventCallback,
                1,
                &eventType,
                userData.toOpaque(),
                &eventHandlerRef
            )
            guard status == noErr else {
                userData.release()
                contextBox = nil
                throw GlobalShortcutError.installHandlerFailed(status)
            }
            contextBox = box
        } else {
            contextBox?.handler = handler
        }

        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = OSType(0x6169_646f) /* 'aido' */
        hotKeyID.id = 1
        var newRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            combo.keyCode,
            combo.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &newRef
        )
        guard status == noErr else {
            logger.error("global shortcut register failed status=\(status) combo=\(combo.displayString, privacy: .public)")
            throw GlobalShortcutError.registerFailed(status)
        }
        hotKeyRef = newRef
        currentCombo = combo
        logger.info("global shortcut registered combo=\(combo.displayString, privacy: .public)")
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
            currentCombo = nil
            logger.info("global shortcut unregistered")
        }
    }

    private nonisolated static func eventCallback(
        _ nextHandler: EventHandlerCallRef?,
        _ event: EventRef?,
        _ userData: UnsafeMutableRawPointer?
    ) -> OSStatus {
        carbonEventCallback(nextHandler, event, userData)
    }
}

/// C 回调入口（文件级函数，可安全转为 C 函数指针）。
/// 只注册了 kEventHotKeyPressed 一种事件类型，回调无需再检查事件种类。
private func carbonEventCallback(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    // 只注册了热键按下事件，无需解包检查事件内容
    guard event != nil, let userData else {
        return CallNextEventHandler(nextHandler, event)
    }
    let box = Unmanaged<HotKeyContextBox>.fromOpaque(userData).takeUnretainedValue()
    box.handler()
    return noErr
}

/// 桥接 C 回调与 Swift 闭包的上下文盒子。
private final class HotKeyContextBox {
    var handler: () -> Void

    init(handler: @escaping () -> Void) {
        self.handler = handler
    }
}
