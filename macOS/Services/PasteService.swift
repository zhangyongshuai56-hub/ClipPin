import AppKit
import ApplicationServices
import Carbon.HIToolbox
import os

/// Quick Paste 服务（§37、§38）。
/// 流程：快照用户原剪贴板 → 复制选中项 → 隐藏窗口 → 激活之前的前台应用 →
/// 合成 ⌘V → 延时恢复用户原剪贴板。无辅助功能权限时由 UI 显式引导，绝不绕过权限机制。
@MainActor
final class PasteService {
    static let shared = PasteService()

    private let logger = Logger(subsystem: "com.aidopaste.app", category: "paste")

    /// 剪贴板窗口弹出前的前台应用（粘贴目标）。
    private(set) var previousApp: NSRunningApplication?

    private init() {}

    // MARK: - 权限（§38）

    var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// 打开系统设置的辅助功能面板。
    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: - 粘贴目标

    /// WindowManager 显示剪贴板窗口前调用：记录粘贴目标应用。
    func noteWindowAboutToShow() {
        previousApp = NSWorkspace.shared.frontmostApplication
    }

    // MARK: - 剪贴板快照（§37：用户原来的 Clipboard 不能被破坏）

    typealias PasteboardSnapshot = [(NSPasteboard.PasteboardType, Data)]

    func captureCurrentContents() -> PasteboardSnapshot {
        let pasteboard = NSPasteboard.general
        guard let types = pasteboard.types else { return [] }
        return types.compactMap { type in
            pasteboard.data(forType: type).map { (type, $0) }
        }
    }

    /// 恢复快照内容；恢复动作本身不进历史（§18）。
    func restore(_ snapshot: PasteboardSnapshot) {
        guard !snapshot.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.declareTypes(snapshot.map(\.0), owner: nil)
        for (type, data) in snapshot {
            pasteboard.setData(data, forType: type)
        }
        ClipboardChangeGate.shared.suppress(pasteboard.changeCount)
        logger.info("pasteboard restored types=\(snapshot.count)")
    }

    // MARK: - 粘贴

    /// 隐藏窗口 → 激活之前的前台应用 → 合成 ⌘V。
    /// 返回 false 表示未能完成（原因已记录）。
    func pasteToPreviousApp(hideWindow: () -> Void) async -> Bool {
        guard let previous = previousApp else {
            logger.error("quick paste aborted: no previous app recorded")
            return false
        }
        hideWindow()
        // 由当前应用发起协作式激活，把焦点让渡给粘贴目标
        let activated = previous.activate(from: .current)
        if !activated {
            logger.error("quick paste aborted: activation refused")
            return false
        }
        // 给目标应用一点完成激活的时间，再注入按键
        try? await Task.sleep(for: .milliseconds(250))
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true) else {
            return false
        }
        keyDown.flags = [.maskCommand]
        keyDown.post(tap: .cghidEventTap)
        if let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) {
            keyUp.flags = [.maskCommand]
            keyUp.post(tap: .cghidEventTap)
        }
        logger.info("quick paste keystroke sent")
        return true
    }
}
